import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

// ============================ VERİ MODELİ ============================
// Tek bir düz liste: her öğe (klasör ya da dosya) "parent" ile üst klasörüne bağlanır.
// Böylece klasör içinde klasör sınırsız derinlikte kurulabilir.
class Item {
  String id;
  String? parent; // null => ana dizin
  String type; // 'folder' | 'file'
  String title;
  String? kind; // is, kamyon, gider, kgider, yakit, mazot, puantaj, musteri
  String? ck; // klasör için: içine eklenecek yeni dosyaların türü
  String note;
  List<String> tpl; // klasör için: yeni dosya form şablonu (alan adları)
  Map<String, String> fields;
  Item({required this.id, this.parent, required this.type, required this.title, this.kind, this.ck,
      this.note = '', List<String>? tpl, Map<String, String>? fields})
      : tpl = tpl ?? [],
        fields = fields ?? {};
  bool get isFolder => type == 'folder';
  factory Item.fromJson(Map<String, dynamic> j) => Item(
      id: j['id'], parent: j['parent'], type: j['type'], title: j['title'], kind: j['kind'], ck: j['ck'],
      note: j['note'] ?? '', tpl: List<String>.from(j['tpl'] ?? []),
      fields: Map<String, String>.from(j['fields'] ?? {}));
  Map<String, dynamic> toJson() => {
        'id': id, 'parent': parent, 'type': type, 'title': title,
        if (kind != null) 'kind': kind,
        if (ck != null) 'ck': ck,
        if (note.isNotEmpty) 'note': note,
        if (tpl.isNotEmpty) 'tpl': tpl,
        if (fields.isNotEmpty) 'fields': fields,
      };
}

// ============================ YARDIMCILAR ============================
String norm(String s) {
  const a = 'İIıÇçĞğÖöŞşÜü';
  const b = 'iiiccggoossuu';
  final o = StringBuffer();
  for (final ch in s.split('')) {
    final i = a.indexOf(ch);
    o.write(i >= 0 ? b[i] : ch);
  }
  return o.toString().toLowerCase().trim();
}

double toD(String? s) => double.tryParse((s ?? '').replaceAll(',', '.')) ?? 0;
double qty(String s) {
  if (s.contains(':')) {
    final p = s.split(':');
    return toD(p[0]) + toD(p[1]) / 60;
  }
  return toD(s);
}

String f2(double x) => (x - x.roundToDouble()).abs() < 1e-6
    ? x.round().toString()
    : x.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');

String tl(double v) {
  final neg = v < 0;
  v = v.abs();
  final p = v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2).split('.');
  p[0] = p[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => '.');
  return '${neg ? '-' : ''}${p.join(',')} ₺';
}

const moneyKeys = {'Saat Ücreti', 'Borç', 'Alınan', 'Kalan', 'Tutar', 'Fiyat'};

// Saat-Sefer x Saat Ücreti => Borç, Borç - Alınan => Kalan (Excel formülleriyle aynı)
Map<String, String> recalc(Map<String, String> f) {
  final o = Map<String, String>.from(f)..remove('Borç')..remove('Kalan');
  if ((o['Saat-Sefer'] ?? '').isNotEmpty && (o['Saat Ücreti'] ?? '').isNotEmpty) {
    final b = qty(o['Saat-Sefer']!) * toD(o['Saat Ücreti']);
    o['Borç'] = f2(b);
    o['Kalan'] = f2(b - toD(o['Alınan']));
  }
  return o;
}

String today() {
  final d = DateTime.now();
  return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
}

String autoTitle(Map<String, String> f) {
  final t = f['Tarih'] ?? '';
  final p = [t.length >= 5 ? t.substring(0, 5) : '', f['Adı Soyadı'] ?? '', f['Makina'] ?? '', f['Tutar'] ?? '']
      .where((e) => e.isNotEmpty);
  return p.isEmpty ? 'Yeni Dosya' : p.join(' · ');
}

// ============================ DEPO (JSON) ============================
class Store extends ChangeNotifier {
  List<Item> items = [];
  late File _file;
  Map<String, int>? _cc;

  Future<void> load() async {
    final dir = await getApplicationDocumentsDirectory();
    _file = File('${dir.path}/data.json');
    String raw;
    if (await _file.exists()) {
      raw = await _file.readAsString();
    } else {
      raw = await rootBundle.loadString('assets/data.json');
      await _file.writeAsString(raw);
    }
    _parse(raw);
  }

  void _parse(String raw) {
    final l = (jsonDecode(raw) as List).map((e) => Item.fromJson(e as Map<String, dynamic>)).toList();
    items = l;
  }

  String exportJson() => jsonEncode(items.map((e) => e.toJson()).toList());
  void commit() {
    _cc = null;
    notifyListeners();
    _file.writeAsString(exportJson());
  }

  Future<void> reset() async {
    _parse(await rootBundle.loadString('assets/data.json'));
    commit();
  }

  bool restore(String raw) {
    try {
      _parse(raw);
      commit();
      return true;
    } catch (_) {
      return false;
    }
  }

  String newId() => 'u${DateTime.now().microsecondsSinceEpoch}';

  Item? byId(String? id) {
    if (id == null) return null;
    for (final i in items) {
      if (i.id == id) return i;
    }
    return null;
  }

  List<Item> children(String? p) {
    final l = items.where((e) => e.parent == p).toList();
    return [...l.where((e) => e.isFolder), ...l.where((e) => !e.isFolder)];
  }

  String path(Item? n) {
    final p = <String>[];
    var c = n;
    while (c != null) {
      p.insert(0, c.title);
      c = byId(c.parent);
    }
    return p.join(' › ');
  }

  // Müşteri klasörü: adı eşleşen tüm iş kayıtları (sanal liste)
  List<Item> matches(Item f) {
    final k = norm(f.title);
    return items
        .where((n) => !n.isFolder && (n.kind == 'is' || n.kind == 'kamyon') && norm(n.fields['Adı Soyadı'] ?? '') == k)
        .toList();
  }

  Map<String, int> get custCount => _cc ??= () {
        final m = <String, int>{};
        for (final n in items) {
          if (!n.isFolder && (n.kind == 'is' || n.kind == 'kamyon')) {
            final k = norm(n.fields['Adı Soyadı'] ?? '');
            m[k] = (m[k] ?? 0) + 1;
          }
        }
        return m;
      }();

  // Bir klasörün altındaki tüm dosyalar (derinlemesine)
  List<Item> files(Item f) {
    final out = <Item>[];
    void walk(String id) {
      for (final n in items) {
        if (n.parent == id) {
          if (n.isFolder) {
            walk(n.id);
          } else {
            out.add(n);
          }
        }
      }
    }

    walk(f.id);
    if (f.kind == 'musteri') out.addAll(matches(f));
    return out;
  }

  void delete(Item n) {
    final ids = <String>{n.id};
    var grow = true;
    while (grow) {
      grow = false;
      for (final i in items) {
        if (i.parent != null && ids.contains(i.parent) && ids.add(i.id)) grow = true;
      }
    }
    items.removeWhere((i) => ids.contains(i.id));
    commit();
  }
}

final S = Store();

// ============================ UYGULAMA ============================
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await S.load();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Dosyalarım',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
        darkTheme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo, brightness: Brightness.dark),
        themeMode: ThemeMode.system,
        home: const FolderPage(null),
      );
}

void push(BuildContext c, Widget w) => Navigator.push(c, MaterialPageRoute(builder: (_) => w));
void openItem(BuildContext c, Item n) => push(c, n.isFolder ? FolderPage(n.id) : FilePage(n.id));
void msg(BuildContext c, String t) => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(t)));

List<MapEntry<String, String>> summary(List<Item> fs) {
  double b = 0, a = 0, k = 0, g = 0, y = 0, m = 0;
  for (final n in fs) {
    final f = n.fields;
    if (n.kind == 'is' || n.kind == 'kamyon') {
      b += toD(f['Borç']);
      a += toD(f['Alınan']);
      k += toD(f['Kalan']);
    } else if (n.kind == 'gider') {
      g += toD(f['Tutar']);
    } else if (n.kind == 'yakit') {
      y += toD(f['Litre']);
    } else if (n.kind == 'mazot') {
      m += toD(f['Litre']);
    }
  }
  return [
    if (b != 0 || a != 0) MapEntry('Borç', tl(b)),
    if (b != 0 || a != 0) MapEntry('Alınan', tl(a)),
    if (b != 0 || a != 0) MapEntry('Kalan', tl(k)),
    if (g != 0) MapEntry('Gider', tl(g)),
    if (y != 0) MapEntry('Yakıt', '${f2(y)} lt'),
    if (m != 0) MapEntry('Depoya giren', '${f2(m)} lt'),
  ];
}

// ---------------- Klasör sayfası ----------------
class FolderPage extends StatelessWidget {
  final String? id;
  const FolderPage(this.id, {super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: S,
      builder: (c, _) {
        final f = S.byId(id);
        if (id != null && f == null) return const Scaffold();
        final kids = <Item>[...S.children(id), if (f != null && f.kind == 'musteri') ...S.matches(f)];
        final sum = f == null ? <MapEntry<String, String>>[] : summary(S.files(f));
        return Scaffold(
          appBar: AppBar(title: Text(f?.title ?? 'Dosyalarım'), actions: [
            if (f != null) IconButton(icon: const Icon(Icons.search), onPressed: () => push(c, const SearchPage())),
            if (f == null)
              PopupMenuButton<String>(
                onSelected: (v) => _menu(c, v),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'b', child: Text('Yedeği panoya kopyala')),
                  PopupMenuItem(value: 'r', child: Text('Panodaki yedeği geri yükle')),
                  PopupMenuItem(value: 'x', child: Text('Excel verisine sıfırla')),
                ],
              ),
          ]),
          body: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
            if (f == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  readOnly: true,
                  onTap: () => push(c, const SearchPage()),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Tüm klasör ve içeriklerde ara…',
                    filled: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(32), borderSide: BorderSide.none),
                  ),
                ),
              ),
            if (f != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(S.path(f), style: Theme.of(c).textTheme.bodySmall),
              ),
            if (sum.isNotEmpty)
              Card(
                margin: const EdgeInsets.all(12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Wrap(spacing: 8, runSpacing: 4, children: [
                    for (final e in sum) Chip(label: Text('${e.key}: ${e.value}')),
                  ]),
                ),
              ),
            if (kids.isEmpty)
              const Padding(padding: EdgeInsets.all(48), child: Center(child: Text('Bu klasör boş. “Ekle” ile başlayın.'))),
            for (final n in kids) _tile(c, n),
          ]),
          floatingActionButton: FloatingActionButton.extended(
              onPressed: () => _addSheet(c, f), icon: const Icon(Icons.add), label: const Text('Ekle')),
        );
      });

  Widget _tile(BuildContext c, Item n) {
    String sub;
    if (n.isFolder) {
      sub = n.kind == 'musteri' ? '${S.custCount[norm(n.title)] ?? 0} kayıt' : '${S.children(n.id).length} öğe';
    } else {
      final es = n.fields.entries.where((x) => x.key != 'Tarih' && x.key != 'Adı Soyadı').take(3);
      sub = es.isNotEmpty ? es.map((x) => '${x.key}: ${x.value}').join(' · ') : n.note.split('\n').first;
    }
    return ListTile(
      leading: Icon(n.isFolder ? Icons.folder : Icons.description_outlined,
          color: n.isFolder ? Colors.amber.shade700 : Theme.of(c).colorScheme.primary),
      title: Text(n.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: sub.isEmpty ? null : Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'e') push(c, EditPage(item: n));
          if (v == 'm') doMove(c, n);
          if (v == 'd') doDelete(c, n);
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'e', child: Text('Düzenle')),
          PopupMenuItem(value: 'm', child: Text('Taşı')),
          PopupMenuItem(value: 'd', child: Text('Sil')),
        ],
      ),
      onTap: () => openItem(c, n),
    );
  }

  void _addSheet(BuildContext c, Item? f) => showModalBottomSheet(
      context: c,
      builder: (x) => SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                  leading: const Icon(Icons.create_new_folder_outlined),
                  title: const Text('Yeni klasör'),
                  onTap: () {
                    Navigator.pop(x);
                    push(c, EditPage(parent: f?.id, folder: true));
                  }),
              ListTile(
                  leading: const Icon(Icons.note_add_outlined),
                  title: const Text('Yeni dosya'),
                  onTap: () {
                    Navigator.pop(x);
                    push(c, EditPage(parent: f?.id));
                  }),
            ]),
          ));

  Future<void> _menu(BuildContext c, String v) async {
    if (v == 'b') {
      await Clipboard.setData(ClipboardData(text: S.exportJson()));
      if (c.mounted) msg(c, 'Yedek panoya kopyalandı. Bir yere yapıştırıp saklayın.');
    } else if (v == 'r') {
      final d = await Clipboard.getData(Clipboard.kTextPlain);
      final ok = S.restore(d?.text ?? '');
      if (c.mounted) msg(c, ok ? 'Yedek geri yüklendi.' : 'Panoda geçerli bir yedek yok.');
    } else if (v == 'x') {
      final ok = await confirm(c, 'Sıfırlansın mı?', 'Yaptığınız tüm değişiklikler silinir, Excel\'den aktarılan ilk veri geri gelir.');
      if (ok) await S.reset();
    }
  }
}

Future<bool> confirm(BuildContext c, String t, String body, [String yes = 'Evet']) async =>
    await showDialog<bool>(
        context: c,
        builder: (x) => AlertDialog(title: Text(t), content: Text(body), actions: [
              TextButton(onPressed: () => Navigator.pop(x, false), child: const Text('Vazgeç')),
              FilledButton(onPressed: () => Navigator.pop(x, true), child: Text(yes)),
            ])) ==
    true;

Future<void> doDelete(BuildContext c, Item n, {bool pop = false}) async {
  final ok = await confirm(c, 'Silinsin mi?',
      n.isFolder ? '"${n.title}" klasörü ve içindeki her şey silinecek.' : '"${n.title}" silinecek.', 'Sil');
  if (!ok) return;
  S.delete(n);
  if (pop && c.mounted) Navigator.pop(c);
}

class Dest {
  final String? id;
  Dest(this.id);
}

Future<void> doMove(BuildContext c, Item n) async {
  String? cur;
  final d = await showDialog<Dest>(
      context: c,
      builder: (_) => StatefulBuilder(builder: (ctx, set) {
            final folders = S.children(cur).where((x) => x.isFolder && x.id != n.id).toList();
            return AlertDialog(
              title: Text(cur == null ? 'Ana dizin' : S.path(S.byId(cur)), style: const TextStyle(fontSize: 14)),
              content: SizedBox(
                width: double.maxFinite,
                height: 340,
                child: ListView(children: [
                  if (cur != null)
                    ListTile(
                        leading: const Icon(Icons.arrow_upward),
                        title: const Text('Üst klasör'),
                        onTap: () => set(() => cur = S.byId(cur)?.parent)),
                  for (final x in folders)
                    ListTile(
                        leading: const Icon(Icons.folder),
                        title: Text(x.title),
                        onTap: () => set(() => cur = x.id)),
                ]),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('İptal')),
                FilledButton(onPressed: () => Navigator.pop(ctx, Dest(cur)), child: const Text('Buraya taşı')),
              ],
            );
          }));
  if (d != null) {
    n.parent = d.id;
    S.commit();
  }
}

// ---------------- Dosya (ayrıntı) sayfası ----------------
class FilePage extends StatelessWidget {
  final String id;
  const FilePage(this.id, {super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: S,
      builder: (c, _) {
        final n = S.byId(id);
        if (n == null) return const Scaffold();
        return Scaffold(
          appBar: AppBar(title: Text(n.title, overflow: TextOverflow.ellipsis), actions: [
            IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => push(c, EditPage(item: n))),
            IconButton(icon: const Icon(Icons.drive_file_move_outline), onPressed: () => doMove(c, n)),
            IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => doDelete(c, n, pop: true)),
          ]),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            Text(S.path(S.byId(n.parent)), style: Theme.of(c).textTheme.bodySmall),
            const SizedBox(height: 12),
            if (n.fields.isNotEmpty)
              Card(
                child: Column(children: [
                  for (final e in n.fields.entries)
                    ListTile(
                      dense: true,
                      title: Text(e.key),
                      trailing: Text(moneyKeys.contains(e.key) ? tl(toD(e.value)) : e.value,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                    ),
                ]),
              ),
            if (n.note.isNotEmpty)
              Card(child: Padding(padding: const EdgeInsets.all(16), child: SelectableText(n.note))),
          ]),
        );
      });
}

// ---------------- Ekle / Düzenle formu ----------------
class _Row {
  final TextEditingController k, v;
  _Row(String a, String b)
      : k = TextEditingController(text: a),
        v = TextEditingController(text: b);
}

class EditPage extends StatefulWidget {
  final Item? item;
  final String? parent;
  final bool folder;
  const EditPage({super.key, this.item, this.parent, this.folder = false});
  @override
  State<EditPage> createState() => _EditState();
}

class _EditState extends State<EditPage> {
  late final TextEditingController t, note;
  final rows = <_Row>[];
  late bool folder;
  Item? get pf => S.byId(widget.parent);

  @override
  void initState() {
    super.initState();
    final it = widget.item;
    folder = it?.isFolder ?? widget.folder;
    t = TextEditingController(text: it?.title ?? '');
    note = TextEditingController(text: it?.note ?? '');
    if (it != null) {
      final auto = it.fields.containsKey('Saat-Sefer') && it.fields.containsKey('Saat Ücreti');
      it.fields.forEach((k, v) {
        if (!(auto && (k == 'Borç' || k == 'Kalan'))) rows.add(_Row(k, v));
      });
    } else if (!folder) {
      for (final k in pf?.tpl ?? <String>[]) {
        rows.add(_Row(k, k == 'Tarih' ? today() : ''));
      }
    }
  }

  void _save() {
    var f = <String, String>{};
    if (!folder) {
      for (final r in rows) {
        final k = r.k.text.trim(), v = r.v.text.trim();
        if (k.isNotEmpty && v.isNotEmpty) f[k] = v;
      }
      f = recalc(f);
    }
    var title = t.text.trim();
    if (title.isEmpty) {
      if (folder) {
        msg(context, 'Klasör adı gerekli.');
        return;
      }
      title = autoTitle(f);
    }
    final it = widget.item;
    if (it != null) {
      it
        ..title = title
        ..note = note.text.trim()
        ..fields = f;
    } else {
      S.items.add(Item(
        id: S.newId(),
        parent: widget.parent,
        type: folder ? 'folder' : 'file',
        title: title,
        kind: folder ? null : pf?.ck,
        ck: folder ? pf?.ck : null,
        tpl: folder ? [...?pf?.tpl] : [],
        note: note.text.trim(),
        fields: f,
      ));
    }
    S.commit();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.item == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? (folder ? 'Yeni klasör' : 'Yeni dosya') : 'Düzenle'),
        actions: [IconButton(icon: const Icon(Icons.check), onPressed: _save)],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
          controller: t,
          decoration: InputDecoration(
              labelText: folder ? 'Klasör adı' : 'Başlık (boşsa otomatik oluşur)', border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 16),
        if (!folder) ...[
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(children: [
                Expanded(
                    flex: 2,
                    child: TextField(
                        controller: r.k, decoration: const InputDecoration(labelText: 'Alan', border: OutlineInputBorder()))),
                const SizedBox(width: 8),
                Expanded(
                    flex: 3,
                    child: TextField(
                      controller: r.v,
                      decoration: InputDecoration(
                        labelText: 'Değer',
                        border: const OutlineInputBorder(),
                        suffixIcon: r.k.text.trim() == 'Tarih'
                            ? IconButton(
                                icon: const Icon(Icons.event),
                                onPressed: () async {
                                  final d = await showDatePicker(
                                      context: context,
                                      initialDate: DateTime.now(),
                                      firstDate: DateTime(2020),
                                      lastDate: DateTime(2040));
                                  if (d != null) {
                                    setState(() => r.v.text =
                                        '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}');
                                  }
                                })
                            : null,
                      ),
                    )),
                IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => rows.remove(r))),
              ]),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
                onPressed: () => setState(() => rows.add(_Row('', ''))),
                icon: const Icon(Icons.add),
                label: const Text('Alan ekle')),
          ),
          const SizedBox(height: 8),
        ],
        TextField(
          controller: note,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(labelText: 'Açıklama / içerik', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(onPressed: _save, icon: const Icon(Icons.save), label: const Text('Kaydet')),
        if (!folder)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text('Not: "Saat-Sefer" (örn. 02:30 ya da 4) ve "Saat Ücreti" doluysa Borç ve Kalan otomatik hesaplanır.',
                style: TextStyle(fontSize: 12)),
          ),
      ]),
    );
  }
}

// ---------------- Arama ----------------
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});
  @override
  State<SearchPage> createState() => _SearchState();
}

class _SearchState extends State<SearchPage> {
  String q = '';

  List<Item> _run() {
    final k = norm(q);
    if (k.isEmpty) return [];
    final out = <Item>[];
    for (final n in S.items) {
      if (norm(n.title).contains(k) ||
          norm(n.note).contains(k) ||
          n.fields.values.any((v) => norm(v).contains(k))) {
        out.add(n);
        if (out.length >= 300) break;
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final res = _run();
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Başlık veya içerikte ara…', border: InputBorder.none),
          onChanged: (v) => setState(() => q = v),
        ),
      ),
      body: q.trim().isEmpty
          ? const Center(child: Text('Aramak için yazmaya başlayın'))
          : res.isEmpty
              ? const Center(child: Text('Sonuç bulunamadı'))
              : ListView.builder(
                  itemCount: res.length,
                  itemBuilder: (c, i) {
                    final n = res[i];
                    final p = S.path(S.byId(n.parent));
                    return ListTile(
                      leading: Icon(n.isFolder ? Icons.folder : Icons.description_outlined,
                          color: n.isFolder ? Colors.amber.shade700 : null),
                      title: Text(n.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(p.isEmpty ? 'Ana dizin' : p, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => openItem(c, n),
                    );
                  },
                ),
    );
  }
}
