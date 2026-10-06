import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

typedef R = Map<String, String>;

const aylar = ['Tümü', 'Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran', 'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık'];
const navy = Color(0xFF1F2937);
const orange = Color(0xFFE8A13A);

// ============================ YARDIMCILAR ============================
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
  final p = v.toStringAsFixed(v.roundToDouble() == v ? 0 : 2).split('.');
  p[0] = p[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => '.');
  return '${neg ? '-' : ''}${p.join(',')} ₺';
}

String hm(double h) {
  final m = (h * 60).round();
  return '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')} sa';
}

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

String dshow(String? iso) => (iso != null && iso.length >= 10) ? '${iso.substring(8, 10)}.${iso.substring(5, 7)}.${iso.substring(0, 4)}' : (iso ?? '');
String dparse(String s) {
  final p = s.trim().split('.');
  if (p.length == 3 && p[2].length == 4) return '${p[2]}-${p[1].padLeft(2, '0')}-${p[0].padLeft(2, '0')}';
  return s.trim();
}

int mon(R r) => int.tryParse((r['tarih'] ?? '').length >= 7 ? r['tarih']!.substring(5, 7) : '') ?? 0;
double borc(R r) => qty(r['miktar'] ?? '') * toD(r['ucret']);
double sum(Iterable<R> l, double Function(R) f) => l.fold(0.0, (a, r) => a + f(r));
void msg(BuildContext c, String t) => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(t)));
void push(BuildContext c, Widget w) => Navigator.push(c, MaterialPageRoute(builder: (_) => w));

// ============================ DEPO (JSON) ============================
class Store extends ChangeNotifier {
  List<R> isler = [], giderler = [], mazot = [];
  List<String> musteriler = [], makinalar = [];
  late File _f;

  Future<void> load() async {
    final dir = await getApplicationDocumentsDirectory();
    _f = File('${dir.path}/veri_v2.json');
    String raw;
    if (await _f.exists()) {
      raw = await _f.readAsString();
    } else {
      raw = await rootBundle.loadString('assets/data.json');
      await _f.writeAsString(raw);
    }
    _parse(raw);
  }

  void _parse(String raw) {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    List<R> lr(String k) => ((j[k] ?? []) as List).map((e) => R.from(e as Map)).toList();
    final a = lr('isler'), b = lr('giderler'), c = lr('mazot');
    final d = List<String>.from(j['musteriler'] ?? []), e = List<String>.from(j['makinalar'] ?? []);
    isler = a;
    giderler = b;
    mazot = c;
    musteriler = d;
    makinalar = e;
  }

  String export() => jsonEncode({'isler': isler, 'giderler': giderler, 'mazot': mazot, 'musteriler': musteriler, 'makinalar': makinalar});
  void commit() {
    notifyListeners();
    _f.writeAsString(export());
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

  String id() => 'u${DateTime.now().microsecondsSinceEpoch}';

  void ensure(R r) {
    final m = (r['musteri'] ?? '').trim(), k = (r['makina'] ?? '').trim();
    if (m.isNotEmpty && !musteriler.any((x) => norm(x) == norm(m))) musteriler.add(m);
    if (k.isNotEmpty && !makinalar.any((x) => norm(x) == norm(k))) makinalar.add(k);
  }

  List<R> byMonth(List<R> l, int m) => m == 0 ? l : l.where((r) => mon(r) == m).toList();

  // Mazot ortalama birim fiyatı: fiyatı girilmiş alımlar / litre
  double get avgPrice {
    double t = 0, l = 0;
    for (final r in mazot) {
      if (r['tur'] != 'cikan' && toD(r['tutar']) > 0 && toD(r['litre']) > 0) {
        t += toD(r['tutar']);
        l += toD(r['litre']);
      }
    }
    return l == 0 ? 0 : t / l;
  }

  double get depo => sum(mazot.where((r) => r['tur'] == 'giren'), (r) => toD(r['litre'])) - sum(mazot.where((r) => r['tur'] == 'cikan'), (r) => toD(r['litre']));
  double alimTl(int m) => sum(byMonth(mazot, m).where((r) => r['tur'] != 'cikan'), (r) => toD(r['tutar']));

  // müşteri adı -> [borç, alınan]
  Map<String, List<double>> get musteriStat {
    final m = <String, List<double>>{};
    for (final r in isler) {
      final v = m.putIfAbsent(norm(r['musteri'] ?? ''), () => [0, 0]);
      v[0] += borc(r);
      v[1] += toD(r['alinan']);
    }
    return m;
  }

  List<MStat> makinaStat(int m) {
    final out = <MStat>[];
    final js = byMonth(isler, m), ms = byMonth(mazot, m);
    for (final name in makinalar) {
      final k = norm(name);
      final mine = js.where((r) => norm(r['makina'] ?? '') == k);
      final s = MStat(name);
      for (final r in mine) {
        final q = r['miktar'] ?? '';
        if (q.contains(':')) {
          s.hrs += qty(q);
        } else {
          s.trips += qty(q);
        }
        s.gelir += borc(r);
      }
      s.litre = sum(ms.where((r) => r['tur'] == 'cikan' && norm(r['makina'] ?? '') == k), (r) => toD(r['litre']));
      s.mazotTl = s.litre * avgPrice;
      out.add(s);
    }
    return out;
  }
}

class MStat {
  final String name;
  double hrs = 0, trips = 0, litre = 0, gelir = 0, mazotTl = 0;
  MStat(this.name);
  double get kar => gelir - mazotTl;
  String get calisma => hrs > 0 ? hm(hrs) + (trips > 0 ? ' + ${f2(trips)} sefer' : '') : '${f2(trips)} sefer';
  double get lPerUnit => hrs > 0 ? litre / hrs : (trips > 0 ? litre / trips : 0);
  bool get active => hrs > 0 || trips > 0 || litre > 0 || gelir > 0;
}

final S = Store();
final ayF = ValueNotifier<int>(0);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await S.load();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'İş Takip',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: orange, brightness: Brightness.light),
          scaffoldBackgroundColor: const Color(0xFFF1F3F5),
          appBarTheme: const AppBarTheme(backgroundColor: navy, foregroundColor: Colors.white),
          cardTheme: CardThemeData(color: Colors.white, elevation: 1, margin: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
        ),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int i = 0;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: IndexedStack(index: i, children: const [OzetTab(), IslerTab(), MazotTab(), MusteriTab(), MakinaTab(), GiderTab()]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: i,
          onDestinationSelected: (v) => setState(() => i = v),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Özet'),
            NavigationDestination(icon: Icon(Icons.agriculture), label: 'İşler'),
            NavigationDestination(icon: Icon(Icons.local_gas_station), label: 'Mazot'),
            NavigationDestination(icon: Icon(Icons.groups), label: 'Müşteri'),
            NavigationDestination(icon: Icon(Icons.build), label: 'Makina'),
            NavigationDestination(icon: Icon(Icons.payments), label: 'Gider'),
          ],
        ),
      );
}

// ============================ FORM ============================
class Fld {
  final String k, l, t; // t: t=metin, n=sayı, d=tarih, p=seçmeli yazı, s=açılır liste, m=çok satır
  final List<String> opts;
  const Fld(this.k, this.l, [this.t = 't', this.opts = const []]);
}

const turler = ['giren=Depoya giriş', 'cikan=Makinaya yakıt (depodan)', 'alim=Dışarıdan alım'];

Future<R?> showForm(BuildContext c, String title, List<Fld> fl, R init, {bool canDelete = false}) =>
    showModalBottomSheet<R>(context: c, isScrollControlled: true, builder: (_) => _FormSheet(title, fl, init, canDelete));

class _FormSheet extends StatefulWidget {
  final String title;
  final List<Fld> fl;
  final R init;
  final bool canDelete;
  const _FormSheet(this.title, this.fl, this.init, this.canDelete);
  @override
  State<_FormSheet> createState() => _FormState();
}

class _FormState extends State<_FormSheet> {
  final ctl = <String, TextEditingController>{};
  @override
  void initState() {
    super.initState();
    for (final f in widget.fl) {
      var v = widget.init[f.k] ?? '';
      if (f.t == 'd') v = v.isEmpty ? dshow(DateTime.now().toIso8601String()) : dshow(v);
      if (f.t == 's' && v.isEmpty) v = f.opts.first.split('=').first;
      ctl[f.k] = TextEditingController(text: v);
    }
  }

  void _save() {
    final o = <String, String>{};
    for (final f in widget.fl) {
      final v = ctl[f.k]!.text.trim();
      o[f.k] = f.t == 'd' ? dparse(v) : v;
    }
    Navigator.pop(context, o);
  }

  Widget _field(Fld f) {
    final c = ctl[f.k]!;
    if (f.t == 's') {
      return DropdownButtonFormField<String>(
        initialValue: c.text,
        decoration: InputDecoration(labelText: f.l, border: const OutlineInputBorder()),
        items: [for (final o in f.opts) DropdownMenuItem(value: o.split('=').first, child: Text(o.split('=').last))],
        onChanged: (v) => c.text = v ?? c.text,
      );
    }
    Widget? suf;
    if (f.t == 'p') {
      suf = PopupMenuButton<String>(
        icon: const Icon(Icons.arrow_drop_down),
        onSelected: (v) => setState(() => c.text = v),
        itemBuilder: (_) => [for (final o in f.opts) PopupMenuItem(value: o, child: Text(o))],
      );
    } else if (f.t == 'd') {
      suf = IconButton(
        icon: const Icon(Icons.event),
        onPressed: () async {
          final d = await showDatePicker(context: context, initialDate: DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime(2040));
          if (d != null) setState(() => c.text = dshow(d.toIso8601String()));
        },
      );
    }
    return TextField(
      controller: c,
      keyboardType: f.t == 'n' ? const TextInputType.numberWithOptions(decimal: true) : (f.t == 'm' ? TextInputType.multiline : TextInputType.text),
      minLines: f.t == 'm' ? 2 : 1,
      maxLines: f.t == 'm' ? 5 : 1,
      decoration: InputDecoration(labelText: f.l, border: const OutlineInputBorder(), suffixIcon: suf),
    );
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 14),
            for (final f in widget.fl) Padding(padding: const EdgeInsets.only(bottom: 12), child: _field(f)),
            Row(children: [
              if (widget.canDelete)
                TextButton.icon(
                    onPressed: () => Navigator.pop(context, <String, String>{'_del': '1'}),
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    label: const Text('Sil', style: TextStyle(color: Colors.red))),
              const Spacer(),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Vazgeç')),
              const SizedBox(width: 8),
              FilledButton(onPressed: _save, child: const Text('Kaydet')),
            ]),
          ]),
        ),
      );
}

Future<void> editRec(BuildContext c, List<R> list, String title, List<Fld> fl, {R? rec, R? defaults}) async {
  final res = await showForm(c, rec == null ? 'Yeni $title' : '$title düzenle', fl, rec ?? defaults ?? {}, canDelete: rec != null);
  if (res == null) return;
  if (res['_del'] == '1') {
    list.remove(rec);
  } else if (rec == null) {
    final n = {'id': S.id(), ...res};
    list.add(n);
    S.ensure(n);
  } else {
    rec.addAll(res);
    S.ensure(rec);
  }
  S.commit();
}

List<Fld> isFl() => [
      Fld('musteri', 'Müşteri / Adı Soyadı', 'p', S.musteriler),
      const Fld('tarih', 'Tarih', 'd'),
      Fld('makina', 'Makina', 'p', S.makinalar),
      const Fld('miktar', 'Saat (örn. 02:30) veya sefer sayısı'),
      const Fld('ucret', 'Birim ücret (₺)', 'n'),
      const Fld('alinan', 'Alınan (₺)', 'n'),
      const Fld('aciklama', 'Açıklama', 'm'),
    ];
List<Fld> giderFl() => [
      Fld('kalem', 'Gider kalemi / kişi', 'p', {...S.giderler.map((e) => e['kalem'] ?? '')}.where((e) => e.isNotEmpty).toList()),
      const Fld('tarih', 'Tarih', 'd'),
      const Fld('tutar', 'Tutar (₺)', 'n'),
      const Fld('aciklama', 'Açıklama', 'm'),
    ];
List<Fld> mazotFl() => [
      const Fld('tur', 'Tür', 's', turler),
      const Fld('tarih', 'Tarih', 'd'),
      Fld('makina', 'Makina (yakıt çıkışında)', 'p', S.makinalar),
      const Fld('litre', 'Litre', 'n'),
      const Fld('tutar', 'Toplam tutar ₺ (alım/girişte, ops.)', 'n'),
      const Fld('aciklama', 'Açıklama', 'm'),
    ];

// ============================ ORTAK BİLEŞENLER ============================
class AyDrop extends StatelessWidget {
  const AyDrop({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
      valueListenable: ayF,
      builder: (_, v, __) => Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: v,
                style: const TextStyle(color: Colors.black87, fontSize: 15),
                items: [for (var i = 0; i < aylar.length; i++) DropdownMenuItem(value: i, child: Text(aylar[i]))],
                onChanged: (x) => ayF.value = x ?? 0,
              ),
            ),
          ));
}

class StatCard extends StatelessWidget {
  final String label, value;
  final Color? color;
  const StatCard(this.label, this.value, {super.key, this.color});
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(label, style: const TextStyle(color: Colors.black54, fontSize: 13)),
            const SizedBox(height: 4),
            FittedBox(fit: BoxFit.scaleDown, child: Text(value, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: color))),
          ]),
        ),
      );
}

const green = Color(0xFF2E9E50), red = Color(0xFFC0392B);
Color signC(double v) => v < 0 ? red : (v > 0 ? green : Colors.black87);

// Arama + liste + (+) butonu olan genel sekme
class ListTab extends StatefulWidget {
  final String title;
  final List<R> Function() items;
  final String Function(R) head, sub;
  final Widget Function(R) trail;
  final List<String> Function(R) hay;
  final Future<void> Function(BuildContext, R?) onEdit;
  final Widget Function(List<R>)? header;
  const ListTab({super.key, required this.title, required this.items, required this.head, required this.sub, required this.trail, required this.hay, required this.onEdit, this.header});
  @override
  State<ListTab> createState() => _ListTabState();
}

class _ListTabState extends State<ListTab> {
  String q = '';
  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: Listenable.merge([S, ayF]),
      builder: (c, _) {
        final k = norm(q);
        var l = widget.items();
        l.sort((a, b) => (b['tarih'] ?? '').compareTo(a['tarih'] ?? ''));
        if (k.isNotEmpty) l = l.where((r) => widget.hay(r).any((h) => norm(h).contains(k))).toList();
        return Scaffold(
          appBar: AppBar(title: Text(widget.title), actions: const [AyDrop()]),
          body: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: TextField(
                onChanged: (v) => setState(() => q = v),
                decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Ara…',
                    filled: true,
                    fillColor: Colors.white,
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none)),
              ),
            ),
            if (widget.header != null) Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 4), child: widget.header!(l)),
            Expanded(
              child: l.isEmpty
                  ? const Center(child: Text('Kayıt yok'))
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 90),
                      itemCount: l.length,
                      itemBuilder: (c, i) => Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          title: Text(widget.head(l[i]), maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(widget.sub(l[i]), maxLines: 2, overflow: TextOverflow.ellipsis),
                          trailing: widget.trail(l[i]),
                          onTap: () => widget.onEdit(c, l[i]),
                        ),
                      ),
                    ),
            ),
          ]),
          floatingActionButton: FloatingActionButton(onPressed: () => widget.onEdit(c, null), child: const Icon(Icons.add)),
        );
      });
}

Widget _two(String a, String b, {Color? bc}) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
      Text(a, style: const TextStyle(fontWeight: FontWeight.w600)),
      Text(b, style: TextStyle(fontSize: 12, color: bc ?? Colors.black54)),
    ]);

// ============================ ÖZET ============================
class OzetTab extends StatelessWidget {
  const OzetTab({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: Listenable.merge([S, ayF]),
      builder: (c, _) {
        final m = ayF.value;
        final js = S.byMonth(S.isler, m);
        final borcT = sum(js, borc), alinan = sum(js, (r) => toD(r['alinan']));
        final kalanAll = sum(S.isler, borc) - sum(S.isler, (r) => toD(r['alinan']));
        final gider = sum(S.byMonth(S.giderler, m), (r) => toD(r['tutar']));
        final alim = S.alimTl(m);
        final net = borcT - gider - alim, kasa = alinan - gider - alim;
        final ms = S.makinaStat(m).where((s) => s.active).toList();
        return Scaffold(
          appBar: AppBar(title: const Text('Özet ve Analiz'), actions: [
            const AyDrop(),
            PopupMenuButton<String>(
              onSelected: (v) => _menu(c, v),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'b', child: Text('Yedeği panoya kopyala')),
                PopupMenuItem(value: 'r', child: Text('Panodaki yedeği geri yükle')),
                PopupMenuItem(value: 'x', child: Text('Excel verisine sıfırla')),
              ],
            ),
          ]),
          body: ListView(padding: const EdgeInsets.all(12), children: [
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.75,
              children: [
                StatCard('Toplam iş (borç)', tl(borcT)),
                StatCard('Alınan', tl(alinan), color: green),
                StatCard('Müşterilerde kalan (tüm zamanlar)', tl(kalanAll), color: red),
                StatCard('Depoda mazot', '${f2(S.depo)} L'),
                StatCard('Giderler', tl(gider), color: red),
                StatCard('Mazot alımı (fiyatı girilenler)', tl(alim), color: red),
                StatCard('Net kâr (iş – gider – mazot)', tl(net), color: signC(net)),
                StatCard('Kasa (alınan – gider – mazot)', tl(kasa), color: signC(kasa)),
              ],
            ),
            const SizedBox(height: 18),
            const Text('📄 Raporlar', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(children: [
                  Row(children: [
                    for (final e in const [['Borçlu\nmüşteriler', 'b'], ['Gider\nraporu', 'g'], ['Makina\nraporu', 'm']])
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: orange, foregroundColor: Colors.white, minimumSize: const Size(0, 64)),
                            onPressed: () => _rapor(c, e[1], m),
                            child: Text(e[0], textAlign: TextAlign.center),
                          ),
                        ),
                      ),
                  ]),
                  const SizedBox(height: 8),
                  const Text('Raporu açıp metni panoya kopyalayarak WhatsApp, e-posta veya Excel\'e yapıştırabilirsiniz.', style: TextStyle(color: Colors.black54, fontSize: 13)),
                ]),
              ),
            ),
            const SizedBox(height: 18),
            const Text('Makina analizi', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Card(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columnSpacing: 18,
                  columns: const [
                    DataColumn(label: Text('Makina')),
                    DataColumn(label: Text('Çalışma')),
                    DataColumn(label: Text('Mazot L'), numeric: true),
                    DataColumn(label: Text('L/birim'), numeric: true),
                    DataColumn(label: Text('Gelir'), numeric: true),
                    DataColumn(label: Text('Mazot ₺'), numeric: true),
                    DataColumn(label: Text('Kâr'), numeric: true),
                  ],
                  rows: [
                    for (final s in ms)
                      DataRow(cells: [
                        DataCell(Text(s.name)),
                        DataCell(Text(s.calisma)),
                        DataCell(Text(f2(s.litre))),
                        DataCell(Text(f2(s.lPerUnit), style: const TextStyle(fontWeight: FontWeight.bold))),
                        DataCell(Text(tl(s.gelir).replaceAll(' ₺', ''))),
                        DataCell(Text(tl(s.mazotTl).replaceAll(' ₺', ''))),
                        DataCell(Text(tl(s.kar).replaceAll(' ₺', ''), style: TextStyle(color: signC(s.kar)))),
                      ]),
                  ],
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('L/birim: litre ÷ (saat veya sefer). Mazot ₺ = litre × fiyatı girilmiş alımların ortalama litre fiyatı.', style: TextStyle(color: Colors.black54, fontSize: 12)),
            ),
          ]),
        );
      });

  Future<void> _menu(BuildContext c, String v) async {
    if (v == 'b') {
      await Clipboard.setData(ClipboardData(text: S.export()));
      if (c.mounted) msg(c, 'Yedek panoya kopyalandı. Bir yere yapıştırıp saklayın.');
    } else if (v == 'r') {
      final d = await Clipboard.getData(Clipboard.kTextPlain);
      final ok = S.restore(d?.text ?? '');
      if (c.mounted) msg(c, ok ? 'Yedek geri yüklendi.' : 'Panoda geçerli bir yedek yok.');
    } else {
      final ok = await showDialog<bool>(
          context: c,
          builder: (x) => AlertDialog(title: const Text('Sıfırlansın mı?'), content: const Text('Yaptığınız tüm değişiklikler silinir, Excel\'den aktarılan ilk veri geri gelir.'), actions: [
                TextButton(onPressed: () => Navigator.pop(x, false), child: const Text('Vazgeç')),
                FilledButton(onPressed: () => Navigator.pop(x, true), child: const Text('Sıfırla')),
              ]));
      if (ok == true) await S.reset();
    }
  }

  void _rapor(BuildContext c, String t, int m) {
    final b = StringBuffer();
    String title;
    if (t == 'b') {
      title = 'Borçlu müşteriler';
      final st = S.musteriStat;
      final l = [for (final n in S.musteriler) MapEntry(n, (st[norm(n)]?[0] ?? 0) - (st[norm(n)]?[1] ?? 0))].where((e) => e.value > 0.5).toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final e in l) {
        b.writeln('${e.key}: ${tl(e.value)}');
      }
      b.writeln('\nTOPLAM: ${tl(l.fold(0.0, (a, e) => a + e.value))}');
    } else if (t == 'g') {
      title = 'Gider raporu (${aylar[m]})';
      final g = <String, double>{};
      for (final r in S.byMonth(S.giderler, m)) {
        g[r['kalem'] ?? '-'] = (g[r['kalem'] ?? '-'] ?? 0) + toD(r['tutar']);
      }
      final l = g.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      for (final e in l) {
        b.writeln('${e.key}: ${tl(e.value)}');
      }
      b.writeln('\nTOPLAM: ${tl(l.fold(0.0, (a, e) => a + e.value))}');
    } else {
      title = 'Makina raporu (${aylar[m]})';
      for (final s in S.makinaStat(m).where((s) => s.active)) {
        b.writeln('${s.name}: ${s.calisma} | ${f2(s.litre)} L | gelir ${tl(s.gelir)} | mazot ${tl(s.mazotTl)} | kâr ${tl(s.kar)}');
      }
    }
    final text = b.toString();
    showDialog(
        context: c,
        builder: (x) => AlertDialog(
              title: Text(title),
              content: SingleChildScrollView(child: SelectableText(text.isEmpty ? 'Kayıt yok' : text)),
              actions: [
                TextButton(onPressed: () => Navigator.pop(x), child: const Text('Kapat')),
                FilledButton(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: '$title\n\n$text'));
                      Navigator.pop(x);
                      msg(c, 'Rapor panoya kopyalandı.');
                    },
                    child: const Text('Kopyala')),
              ],
            ));
  }
}

// ============================ İŞLER ============================
class IslerTab extends StatelessWidget {
  const IslerTab({super.key});
  @override
  Widget build(BuildContext context) => ListTab(
        title: 'İşler',
        items: () => S.byMonth(S.isler, ayF.value).toList(),
        head: (r) => r['musteri'] ?? '-',
        sub: (r) => '${dshow(r['tarih'])} · ${r['makina'] ?? ''} · ${r['miktar'] ?? ''}${(r['aciklama'] ?? '').isEmpty ? '' : '\n${r['aciklama']}'}',
        trail: (r) {
          final b = borc(r), k = b - toD(r['alinan']);
          return _two(tl(b), k.abs() < 0.5 ? 'ödendi' : 'kalan ${tl(k)}', bc: k > 0.5 ? red : green);
        },
        hay: (r) => [r['musteri'] ?? '', r['makina'] ?? '', r['aciklama'] ?? '', dshow(r['tarih']), r['miktar'] ?? ''],
        onEdit: (c, r) => editRec(c, S.isler, 'iş', isFl(), rec: r),
        header: (l) => Card(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              _two(tl(sum(l, borc)), 'Borç'),
              _two(tl(sum(l, (r) => toD(r['alinan']))), 'Alınan'),
              _two(tl(sum(l, borc) - sum(l, (r) => toD(r['alinan']))), 'Kalan'),
            ]),
          ),
        ),
      );
}

// ============================ MAZOT ============================
class MazotTab extends StatelessWidget {
  const MazotTab({super.key});
  @override
  Widget build(BuildContext context) => ListTab(
        title: 'Mazot',
        items: () => S.byMonth(S.mazot, ayF.value).toList(),
        head: (r) => r['tur'] == 'giren' ? '⬇ Depoya giriş' : (r['tur'] == 'cikan' ? '⛽ ${r['makina'] ?? 'Makina'}' : '🛒 Dışarıdan alım'),
        sub: (r) => '${dshow(r['tarih'])}${(r['aciklama'] ?? '').isEmpty ? '' : ' · ${r['aciklama']}'}',
        trail: (r) => _two('${r['litre'] ?? '0'} L', toD(r['tutar']) > 0 ? tl(toD(r['tutar'])) : ''),
        hay: (r) => [r['makina'] ?? '', r['aciklama'] ?? '', dshow(r['tarih']), r['litre'] ?? ''],
        onEdit: (c, r) => editRec(c, S.mazot, 'mazot kaydı', mazotFl(), rec: r, defaults: {'tur': 'cikan'}),
        header: (l) => Card(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              _two('${f2(S.depo)} L', 'Depoda (toplam)'),
              _two('${f2(sum(l.where((r) => r['tur'] == 'giren'), (r) => toD(r['litre'])))} L', 'Giren'),
              _two('${f2(sum(l.where((r) => r['tur'] == 'cikan'), (r) => toD(r['litre'])))} L', 'Çıkan'),
            ]),
          ),
        ),
      );
}

// ============================ GİDER ============================
class GiderTab extends StatelessWidget {
  const GiderTab({super.key});
  @override
  Widget build(BuildContext context) => ListTab(
        title: 'Gider',
        items: () => S.byMonth(S.giderler, ayF.value).toList(),
        head: (r) => r['kalem'] ?? '-',
        sub: (r) => '${dshow(r['tarih'])}${(r['aciklama'] ?? '').isEmpty ? '' : ' · ${r['aciklama']}'}',
        trail: (r) => Text(tl(toD(r['tutar'])), style: const TextStyle(fontWeight: FontWeight.w600, color: red)),
        hay: (r) => [r['kalem'] ?? '', r['aciklama'] ?? '', dshow(r['tarih']), r['tutar'] ?? ''],
        onEdit: (c, r) => editRec(c, S.giderler, 'gider', giderFl(), rec: r),
        header: (l) => Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('${l.length} kayıt'),
              Text('Toplam: ${tl(sum(l, (r) => toD(r['tutar'])))}', style: const TextStyle(fontWeight: FontWeight.bold, color: red)),
            ]),
          ),
        ),
      );
}

// ============================ MÜŞTERİ ============================
Future<String?> askName(BuildContext c, String title, [String init = '']) {
  final t = TextEditingController(text: init);
  return showDialog<String>(
      context: c,
      builder: (x) => AlertDialog(
            title: Text(title),
            content: TextField(controller: t, autofocus: true, decoration: const InputDecoration(border: OutlineInputBorder())),
            actions: [
              TextButton(onPressed: () => Navigator.pop(x), child: const Text('Vazgeç')),
              FilledButton(onPressed: () => Navigator.pop(x, t.text.trim()), child: const Text('Kaydet')),
            ],
          ));
}

class MusteriTab extends StatefulWidget {
  const MusteriTab({super.key});
  @override
  State<MusteriTab> createState() => _MusteriState();
}

class _MusteriState extends State<MusteriTab> {
  String q = '';
  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: S,
      builder: (c, _) {
        final st = S.musteriStat;
        final k = norm(q);
        final l = [for (final n in S.musteriler) if (k.isEmpty || norm(n).contains(k)) n];
        double kal(String n) => (st[norm(n)]?[0] ?? 0) - (st[norm(n)]?[1] ?? 0);
        l.sort((a, b) => kal(b).compareTo(kal(a)));
        return Scaffold(
          appBar: AppBar(title: const Text('Müşteriler')),
          body: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: TextField(
                onChanged: (v) => setState(() => q = v),
                decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search), hintText: 'Müşteri ara…', filled: true, fillColor: Colors.white, isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none)),
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 90),
                itemCount: l.length,
                itemBuilder: (c, i) {
                  final n = l[i], s = st[norm(n)] ?? [0, 0];
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      title: Text(n),
                      subtitle: Text('Borç ${tl(s[0])} · Alınan ${tl(s[1])}'),
                      trailing: Text(tl(s[0] - s[1]), style: TextStyle(fontWeight: FontWeight.w600, color: (s[0] - s[1]) > 0.5 ? red : green)),
                      onTap: () => push(c, MusteriDetay(n)),
                    ),
                  );
                },
              ),
            ),
          ]),
          floatingActionButton: FloatingActionButton(
            onPressed: () async {
              final n = await askName(c, 'Yeni müşteri');
              if (n != null && n.isNotEmpty && !S.musteriler.any((x) => norm(x) == norm(n))) {
                S.musteriler.add(n);
                S.commit();
              }
            },
            child: const Icon(Icons.person_add),
          ),
        );
      });
}

class MusteriDetay extends StatelessWidget {
  final String name;
  const MusteriDetay(this.name, {super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: S,
      builder: (c, _) {
        final l = S.isler.where((r) => norm(r['musteri'] ?? '') == norm(name)).toList()..sort((a, b) => (b['tarih'] ?? '').compareTo(a['tarih'] ?? ''));
        final b = sum(l, borc), a = sum(l, (r) => toD(r['alinan']));
        return Scaffold(
          appBar: AppBar(title: Text(name, overflow: TextOverflow.ellipsis), actions: [
            IconButton(
                icon: const Icon(Icons.edit),
                onPressed: () async {
                  final n = await askName(c, 'Müşteri adı', name);
                  if (n == null || n.isEmpty) return;
                  for (final r in l) {
                    r['musteri'] = n;
                  }
                  final i = S.musteriler.indexWhere((x) => norm(x) == norm(name));
                  if (i >= 0) S.musteriler[i] = n;
                  S.commit();
                  if (c.mounted) Navigator.pop(c);
                }),
            IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  if (l.isNotEmpty) {
                    msg(c, 'Bu müşterinin ${l.length} iş kaydı var. Önce kayıtları silin veya başka müşteriye taşıyın.');
                    return;
                  }
                  S.musteriler.removeWhere((x) => norm(x) == norm(name));
                  S.commit();
                  Navigator.pop(c);
                }),
          ]),
          body: ListView(padding: const EdgeInsets.all(12), children: [
            Row(children: [
              Expanded(child: StatCard('Borç', tl(b))),
              const SizedBox(width: 8),
              Expanded(child: StatCard('Alınan', tl(a), color: green)),
              const SizedBox(width: 8),
              Expanded(child: StatCard('Kalan', tl(b - a), color: (b - a) > 0.5 ? red : green)),
            ]),
            const SizedBox(height: 12),
            for (final r in l)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  title: Text('${dshow(r['tarih'])} · ${r['makina'] ?? ''}'),
                  subtitle: Text('${r['miktar'] ?? ''} × ${r['ucret'] ?? ''}${(r['aciklama'] ?? '').isEmpty ? '' : '\n${r['aciklama']}'}'),
                  trailing: _two(tl(borc(r)), 'alınan ${tl(toD(r['alinan']))}'),
                  onTap: () => editRec(c, S.isler, 'iş', isFl(), rec: r),
                ),
              ),
          ]),
          floatingActionButton: FloatingActionButton(onPressed: () => editRec(c, S.isler, 'iş', isFl(), defaults: {'musteri': name}), child: const Icon(Icons.add)),
        );
      });
}

// ============================ MAKİNA ============================
class MakinaTab extends StatelessWidget {
  const MakinaTab({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: Listenable.merge([S, ayF]),
      builder: (c, _) {
        final l = S.makinaStat(ayF.value);
        return Scaffold(
          appBar: AppBar(title: const Text('Makinalar'), actions: const [AyDrop()]),
          body: ListView(padding: const EdgeInsets.fromLTRB(12, 10, 12, 90), children: [
            for (final s in l)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: const Icon(Icons.precision_manufacturing),
                  title: Text(s.name),
                  subtitle: Text('${s.active ? s.calisma : 'Kayıt yok'} · ${f2(s.litre)} L yakıt'),
                  trailing: _two(tl(s.gelir), 'kâr ${tl(s.kar)}', bc: signC(s.kar)),
                  onTap: () => _opts(c, s.name),
                ),
              ),
          ]),
          floatingActionButton: FloatingActionButton(
            onPressed: () async {
              final n = await askName(c, 'Yeni makina');
              if (n != null && n.isNotEmpty && !S.makinalar.any((x) => norm(x) == norm(n))) {
                S.makinalar.add(n);
                S.commit();
              }
            },
            child: const Icon(Icons.add),
          ),
        );
      });

  void _opts(BuildContext c, String name) => showModalBottomSheet(
      context: c,
      builder: (x) => SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                  leading: const Icon(Icons.edit),
                  title: const Text('Yeniden adlandır'),
                  onTap: () async {
                    Navigator.pop(x);
                    final n = await askName(c, 'Makina adı', name);
                    if (n == null || n.isEmpty) return;
                    for (final r in [...S.isler, ...S.mazot]) {
                      if (norm(r['makina'] ?? '') == norm(name)) r['makina'] = n;
                    }
                    final i = S.makinalar.indexWhere((e) => norm(e) == norm(name));
                    if (i >= 0) S.makinalar[i] = n;
                    S.commit();
                  }),
              ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.red),
                  title: const Text('Listeden sil'),
                  subtitle: const Text('Eski kayıtlar silinmez, sadece liste girişi kalkar'),
                  onTap: () {
                    Navigator.pop(x);
                    S.makinalar.removeWhere((e) => norm(e) == norm(name));
                    S.commit();
                  }),
            ]),
          ));
}
