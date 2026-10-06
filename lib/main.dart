import 'dart:convert';
import 'dart:io' show File;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

typedef R = Map<String, String>;

const aylar = ['Tümü', 'Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran', 'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık'];
const navy = Color(0xFF1F2937);
const amber = Color(0xFFE8A13A);
const bg = Color(0xFFF4F5F7);
const line = Color(0xFFE5E7EB);
const gold = Color(0xFFF59E0B);
const goldBg = Color(0xFFFFF8E6);
const green = Color(0xFF16A34A);
const red = Color(0xFFDC2626);
const orange = Color(0xFFEA580C);
const blue = Color(0xFF2563EB);
const grey = Color(0xFF6B7280);

// ============================ YARDIMCILAR ============================
double toD(String? s) => double.tryParse((s ?? '').replaceAll(',', '.')) ?? 0;
double qty(String s) {
  if (s.contains(':')) {
    final p = s.split(':');
    return toD(p[0]) + toD(p.length > 1 ? p[1] : '0') / 60;
  }
  return toD(s);
}

String f2(double x) => (x - x.roundToDouble()).abs() < 1e-6
    ? x.round().toString()
    : x.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
String tl(double v, [String s = '₺']) {
  final neg = v < 0;
  v = v.abs();
  final p = v.toStringAsFixed(v.roundToDouble() == v ? 0 : 2).split('.');
  p[0] = p[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => '.');
  return '${neg ? '-' : ''}${p.join(',')} $s';
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

String todayIso() => DateTime.now().toIso8601String().substring(0, 10);
int mon(R r) => int.tryParse((r['tarih'] ?? '').length >= 7 ? r['tarih']!.substring(5, 7) : '') ?? 0;
double borc(R r) => qty(r['miktar'] ?? '') * toD(r['ucret']);
double sum(Iterable<R> l, double Function(R) f) => l.fold(0.0, (a, r) => a + f(r));
int cmpDate(R a, R b) => (a['tarih'] ?? '').compareTo(b['tarih'] ?? '');
int daysSince(String? iso) {
  final d = DateTime.tryParse(iso ?? '');
  return d == null ? 0 : DateTime.now().difference(d).inDays;
}

void msg(BuildContext c, String t) => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(t)));
void push(BuildContext c, Widget w) => Navigator.push(c, MaterialPageRoute(builder: (_) => w));
Color signC(double v) => v < 0 ? red : (v > 0 ? green : Colors.black87);

const durumAd = {'hic': 'Hiç ödemedi', 'kismen': 'Kısmen ödedi', 'tam': 'Tamamını ödedi', 'yok': 'İş kaydı yok'};
const durumRenk = {'hic': red, 'kismen': orange, 'tam': green, 'yok': grey};

// ============================ DEPO (JSON) ============================
class CStat {
  final String name;
  double borc = 0, alinan = 0, yil = 0;
  int n = 0;
  String? last, oldest;
  CStat(this.name);
  double get kalan => borc - alinan;
  String get durum => (borc <= 0 && alinan <= 0) ? 'yok' : (alinan <= 0 ? 'hic' : (kalan <= 0.5 ? 'tam' : 'kismen'));
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

class Store extends ChangeNotifier {
  List<R> isler = [], giderler = [], mazot = [];
  List<String> musteriler = [], makinalar = [];
  late File _f;
  Map<String, CStat>? _cs;
  List<CStat>? _top;

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
    _cs = null;
    _top = null;
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

  String get year {
    var y = '${DateTime.now().year}';
    if (isler.any((r) => (r['tarih'] ?? '').startsWith(y))) return y;
    var best = '';
    for (final r in isler) {
      final t = r['tarih'] ?? '';
      if (t.length >= 4 && t.substring(0, 4).compareTo(best) > 0) best = t.substring(0, 4);
    }
    return best.isEmpty ? y : best;
  }

  // Müşteri istatistikleri: borç, alınan, durum, en eski ödenmemiş iş (FIFO)
  Map<String, CStat> get cust {
    if (_cs != null) return _cs!;
    final m = <String, CStat>{};
    for (final n in musteriler) {
      m[norm(n)] = CStat(n);
    }
    final byC = <String, List<R>>{};
    for (final r in isler) {
      final k = norm(r['musteri'] ?? '');
      (byC[k] ??= []).add(r);
      m.putIfAbsent(k, () => CStat((r['musteri'] ?? '').trim().isEmpty ? 'Belirsiz' : r['musteri']!.trim()));
    }
    final y = year;
    byC.forEach((k, l) {
      final s = m[k]!;
      l.sort(cmpDate);
      for (final r in l) {
        final b = borc(r);
        s.borc += b;
        s.alinan += toD(r['alinan']);
        if (b > 0) s.n++;
        final t = r['tarih'] ?? '';
        if (t.isNotEmpty && (s.last == null || t.compareTo(s.last!) > 0)) s.last = t;
        if (t.startsWith(y)) s.yil += b;
      }
      double cum = 0;
      for (final r in l) {
        final b = borc(r);
        if (b > 0) {
          cum += b;
          if (cum > s.alinan + 0.5) {
            s.oldest = r['tarih'];
            break;
          }
        }
      }
    });
    return _cs = m;
  }

  List<CStat> get top5 {
    if (_top != null) return _top!;
    final l = cust.values.where((s) => s.yil > 0).toList()..sort((a, b) => b.yil.compareTo(a.yil));
    return _top = l.take(5).toList();
  }

  int rank(String name) => top5.indexWhere((s) => norm(s.name) == norm(name));

  List<MStat> makinaStat(int m) {
    final out = <MStat>[];
    final js = byMonth(isler, m), ms = byMonth(mazot, m);
    for (final name in makinalar) {
      final k = norm(name);
      final s = MStat(name);
      for (final r in js.where((r) => norm(r['makina'] ?? '') == k)) {
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
          colorScheme: ColorScheme.fromSeed(seedColor: amber, brightness: Brightness.light),
          scaffoldBackgroundColor: bg,
          appBarTheme: const AppBarTheme(
              backgroundColor: navy, foregroundColor: Colors.white, elevation: 0, titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white)),
          navigationBarTheme: NavigationBarThemeData(
              backgroundColor: Colors.white, indicatorColor: amber.withAlpha(70), labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
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
        body: IndexedStack(index: i, children: [const OzetTab(), IslerTab(), MazotTab(), const MusteriTab(), const MakinaTab(), GiderTab()]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: i,
          onDestinationSelected: (v) => setState(() => i = v),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Özet'),
            NavigationDestination(icon: Icon(Icons.agriculture_outlined), selectedIcon: Icon(Icons.agriculture), label: 'İşler'),
            NavigationDestination(icon: Icon(Icons.local_gas_station_outlined), selectedIcon: Icon(Icons.local_gas_station), label: 'Mazot'),
            NavigationDestination(icon: Icon(Icons.groups_outlined), selectedIcon: Icon(Icons.groups), label: 'Müşteri'),
            NavigationDestination(icon: Icon(Icons.precision_manufacturing_outlined), selectedIcon: Icon(Icons.precision_manufacturing), label: 'Makina'),
            NavigationDestination(icon: Icon(Icons.payments_outlined), selectedIcon: Icon(Icons.payments), label: 'Gider'),
          ],
        ),
      );
}

// ============================ ORTAK BİLEŞENLER ============================
class Box extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final Color? color, border;
  final EdgeInsets pad;
  final double bottom;
  const Box({super.key, required this.child, this.onTap, this.color, this.border, this.pad = const EdgeInsets.all(14), this.bottom = 10});
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: Material(
          color: color ?? Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: border ?? line, width: border == null ? 1 : 1.6)),
          child: InkWell(borderRadius: BorderRadius.circular(16), onTap: onTap, child: Padding(padding: pad, child: child)),
        ),
      );
}

class Pill extends StatelessWidget {
  final String t;
  final Color c;
  const Pill(this.t, this.c, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: c.withAlpha(30), borderRadius: BorderRadius.circular(20)),
        child: Text(t, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c)),
      );
}

class Avatar extends StatelessWidget {
  final String name;
  final IconData? icon;
  const Avatar(this.name, {super.key, this.icon});
  @override
  Widget build(BuildContext context) {
    const pal = [blue, green, orange, Color(0xFF7C3AED), Color(0xFF0891B2), Color(0xFFDB2777)];
    final col = pal[name.runes.fold(0, (a, b) => a + b) % pal.length];
    final t = name.trim();
    return CircleAvatar(
      radius: 20,
      backgroundColor: col.withAlpha(35),
      child: icon != null ? Icon(icon, color: col, size: 20) : Text(t.isEmpty ? '?' : String.fromCharCode(t.runes.first).toUpperCase(), style: TextStyle(color: col, fontWeight: FontWeight.w700)),
    );
  }
}

class StatCard extends StatelessWidget {
  final String label, value;
  final Color? color;
  final IconData? icon;
  const StatCard(this.label, this.value, {super.key, this.color, this.icon});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          Row(children: [
            if (icon != null) Icon(icon, size: 15, color: color ?? grey),
            if (icon != null) const SizedBox(width: 4),
            Expanded(child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: grey, fontSize: 12))),
          ]),
          const SizedBox(height: 6),
          FittedBox(fit: BoxFit.scaleDown, child: Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: color ?? Colors.black87))),
        ]),
      );
}

Widget two(String a, String b, {Color? ac, Color? bc}) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
      Text(a, style: TextStyle(fontWeight: FontWeight.w700, color: ac)),
      Text(b, style: TextStyle(fontSize: 11.5, color: bc ?? grey)),
    ]);

Widget secTitle(String t, {Widget? trailing}) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
      child: Row(children: [
        Expanded(child: Text(t.toUpperCase(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: .6, color: grey))),
        if (trailing != null) trailing,
      ]),
    );

Widget searchBox(ValueChanged<String> f, String hint) => TextField(
      onChanged: f,
      decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search), hintText: hint, filled: true, fillColor: Colors.white, isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: line)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: line))),
    );

Widget agePill(CStat s) {
  if (s.oldest == null || s.kalan <= 0.5) return const SizedBox();
  final d = daysSince(s.oldest);
  final col = d > 60 ? red : (d > 30 ? orange : grey);
  return Pill('En eski ödenmemiş iş: ${dshow(s.oldest)} · $d gün', col);
}

class AyDrop extends StatelessWidget {
  const AyDrop({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
      valueListenable: ayF,
      builder: (_, v, __) => Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: v,
                style: const TextStyle(color: Colors.black87, fontSize: 14, fontWeight: FontWeight.w600),
                items: [for (var i = 0; i < aylar.length; i++) DropdownMenuItem(value: i, child: Text(aylar[i]))],
                onChanged: (x) => ayF.value = x ?? 0,
              ),
            ),
          ));
}

Future<String?> pickKey(BuildContext c, String title, List<String> opts, String? cur) {
  var q = '';
  return showDialog<String>(
      context: c,
      builder: (_) => StatefulBuilder(builder: (ctx, set) {
            final k = norm(q);
            final l = opts.where((o) => k.isEmpty || norm(o).contains(k)).toList();
            return AlertDialog(
              title: Text(title),
              content: SizedBox(
                width: double.maxFinite,
                height: 420,
                child: Column(children: [
                  TextField(autofocus: true, decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Ara…'), onChanged: (v) => set(() => q = v)),
                  Expanded(
                    child: ListView(children: [
                      if (k.isEmpty) ListTile(leading: const Icon(Icons.clear_all), title: const Text('Tümü'), onTap: () => Navigator.pop(ctx, '')),
                      for (final o in l) ListTile(title: Text(o), selected: o == cur, onTap: () => Navigator.pop(ctx, o)),
                    ]),
                  ),
                ]),
              ),
            );
          }));
}

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

// ============================ FORM ============================
class Fld {
  final String k, l, t; // t=metin, n=sayı, d=tarih, p=seçmeli yazı, s=açılır liste, m=çok satır
  final List<String> opts;
  const Fld(this.k, this.l, [this.t = 't', this.opts = const []]);
}

const turler = ['giren=Depoya giriş', 'cikan=Makinaya yakıt (depodan)', 'alim=Dışarıdan alım'];

Future<R?> showForm(BuildContext c, String title, List<Fld> fl, R init, {bool canDelete = false}) =>
    showModalBottomSheet<R>(context: c, isScrollControlled: true, showDragHandle: true, builder: (_) => _FormSheet(title, fl, init, canDelete));

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
      if (f.t == 'd') v = dshow(v.isEmpty ? todayIso() : v);
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
        padding: EdgeInsets.fromLTRB(16, 4, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 14),
            for (final f in widget.fl) Padding(padding: const EdgeInsets.only(bottom: 12), child: _field(f)),
            Row(children: [
              if (widget.canDelete)
                TextButton.icon(
                    onPressed: () => Navigator.pop(context, <String, String>{'_del': '1'}),
                    icon: const Icon(Icons.delete_outline, color: red),
                    label: const Text('Sil', style: TextStyle(color: red))),
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
    final n = <String, String>{'id': S.id(), ...(defaults ?? {}), ...res};
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
List<Fld> tahsilatFl() => const [Fld('tarih', 'Tarih', 'd'), Fld('alinan', 'Tahsil edilen tutar (₺)', 'n'), Fld('aciklama', 'Açıklama', 'm')];
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

// ============================ RAPOR (PDF / EXCEL) ============================
class Rep {
  final String title, sub;
  final List<String> head;
  final List<List<Object>> rows;
  final List<Object> foot;
  final Set<int> money;
  final List<Rep> extra;
  Rep(this.title, this.head, this.rows, {this.sub = '', this.foot = const [], this.money = const {}, this.extra = const []});
}

String cellText(Object v, int col, Rep r, {bool pdf = false}) {
  if (v is num) return r.money.contains(col) ? tl(v.toDouble(), pdf ? 'TL' : '₺') : f2(v.toDouble());
  return v.toString();
}

String toText(Rep r) {
  final b = StringBuffer('${r.title}\n${r.sub}\n\n');
  for (final row in r.rows) {
    b.writeln([for (var i = 0; i < row.length; i++) cellText(row[i], i, r)].join(' | '));
  }
  if (r.foot.isNotEmpty) b.writeln('\n${[for (var i = 0; i < r.foot.length; i++) cellText(r.foot[i], i, r)].join(' | ')}');
  return b.toString();
}

// ---- PDF ----
List<pw.Widget> _pdfBlock(Rep r) {
  final n = r.head.length;
  final w = <int, pw.TableColumnWidth>{};
  for (var i = 0; i < n; i++) {
    var m = r.head[i].length;
    for (final row in r.rows) {
      final l = cellText(row[i], i, r, pdf: true).length;
      if (l > m) m = l;
    }
    w[i] = pw.FlexColumnWidth(m.clamp(4, 26).toDouble());
  }
  final right = [for (var i = 0; i < n; i++) r.rows.isNotEmpty && r.rows.first[i] is num];
  pw.Widget cell(String t, int i, {bool bold = false}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        child: pw.Align(
            alignment: right[i] ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
            child: pw.Text(t, style: pw.TextStyle(fontSize: 8.5, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal))),
      );
  return [
    pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(color: PdfColor.fromHex('#1F2937'), borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6))),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text(r.title, style: pw.TextStyle(color: PdfColors.white, fontSize: 15, fontWeight: pw.FontWeight.bold)),
        if (r.sub.isNotEmpty) pw.Text(r.sub, style: const pw.TextStyle(color: PdfColors.grey300, fontSize: 9)),
      ]),
    ),
    pw.SizedBox(height: 8),
    pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.4),
      columnWidths: w,
      children: [
        pw.TableRow(repeat: true, decoration: pw.BoxDecoration(color: PdfColor.fromHex('#E5E7EB')), children: [for (var i = 0; i < n; i++) cell(r.head[i], i, bold: true)]),
        for (var k = 0; k < r.rows.length; k++)
          pw.TableRow(
              decoration: k.isOdd ? pw.BoxDecoration(color: PdfColor.fromHex('#F9FAFB')) : null,
              children: [for (var i = 0; i < n; i++) cell(cellText(r.rows[k][i], i, r, pdf: true), i)]),
        if (r.foot.isNotEmpty)
          pw.TableRow(
              decoration: pw.BoxDecoration(color: PdfColor.fromHex('#FDE9C4')),
              children: [for (var i = 0; i < n; i++) cell(cellText(r.foot[i], i, r, pdf: true), i, bold: true)]),
      ],
    ),
    pw.SizedBox(height: 16),
  ];
}

Future<List<int>> toPdf(Rep r) async {
  final reg = pw.Font.ttf(await rootBundle.load('assets/fonts/LiberationSans-Regular.ttf'));
  final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/LiberationSans-Bold.ttf'));
  final doc = pw.Document(theme: pw.ThemeData.withFont(base: reg, bold: bold));
  final wide = r.head.length > 6 || r.extra.any((e) => e.head.length > 6);
  doc.addPage(pw.MultiPage(
    pageFormat: wide ? PdfPageFormat.a4.landscape : PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(28),
    footer: (ctx) => pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
      pw.Text('İş Takip · ${dshow(todayIso())}', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
      pw.Text('Sayfa ${ctx.pageNumber}/${ctx.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
    ]),
    build: (ctx) => [..._pdfBlock(r), for (final e in r.extra) ..._pdfBlock(e)],
  ));
  return doc.save();
}

// ---- EXCEL (.xlsx, harici paket gerektirmez) ----
final _crcT = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
  }
  return c;
});
int _crc32(List<int> d) {
  var c = 0xFFFFFFFF;
  for (final b in d) {
    c = _crcT[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

Uint8List _zip(Map<String, List<int>> files) {
  final out = BytesBuilder(), cd = BytesBuilder();
  void w16(BytesBuilder b, int v) => b.add([v & 255, (v >> 8) & 255]);
  void w32(BytesBuilder b, int v) => b.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
  var off = 0;
  files.forEach((name, data) {
    final n = utf8.encode(name), c = _crc32(data);
    w32(out, 0x04034b50);
    w16(out, 20);
    w16(out, 0x0800);
    w16(out, 0);
    w16(out, 0);
    w16(out, 0x21);
    w32(out, c);
    w32(out, data.length);
    w32(out, data.length);
    w16(out, n.length);
    w16(out, 0);
    out.add(n);
    out.add(data);
    w32(cd, 0x02014b50);
    w16(cd, 20);
    w16(cd, 20);
    w16(cd, 0x0800);
    w16(cd, 0);
    w16(cd, 0);
    w16(cd, 0x21);
    w32(cd, c);
    w32(cd, data.length);
    w32(cd, data.length);
    w16(cd, n.length);
    w16(cd, 0);
    w16(cd, 0);
    w16(cd, 0);
    w16(cd, 0);
    w32(cd, 0);
    w32(cd, off);
    cd.add(n);
    off += 30 + n.length + data.length;
  });
  final cdb = cd.toBytes();
  out.add(cdb);
  w32(out, 0x06054b50);
  w16(out, 0);
  w16(out, 0);
  w16(out, files.length);
  w16(out, files.length);
  w32(out, cdb.length);
  w32(out, off);
  w16(out, 0);
  return out.toBytes();
}

String _esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
String _col(int i) {
  var s = '';
  var n = i + 1;
  while (n > 0) {
    final r = (n - 1) % 26;
    s = String.fromCharCode(65 + r) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

const _xh = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
const _styles = '$_xh<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="1"><numFmt numFmtId="164" formatCode="#,##0.00"/></numFmts>'
    '<fonts count="4"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="14"/><name val="Calibri"/></font></fonts>'
    '<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF1F2937"/><bgColor indexed="64"/></patternFill></fill></fills>'
    '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
    '<cellXfs count="5"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>'
    '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="164" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1" applyNumberFormat="1"/>'
    '<xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs></styleSheet>';

String _sheetXml(Rep r) {
  final rows = <List<List<Object>>>[]; // her hücre: [değer, stil]
  rows.add([[r.title, 4]]);
  if (r.sub.isNotEmpty) rows.add([[r.sub, 0]]);
  rows.add([]);
  rows.add([for (final h in r.head) [h, 1]]);
  for (final row in r.rows) {
    rows.add([for (var i = 0; i < row.length; i++) [row[i], (row[i] is num && r.money.contains(i)) ? 2 : 0]]);
  }
  if (r.foot.isNotEmpty) rows.add([for (var i = 0; i < r.foot.length; i++) [r.foot[i], (r.foot[i] is num && r.money.contains(i)) ? 3 : 3]]);
  final widths = [for (var i = 0; i < r.head.length; i++) r.head[i].length];
  for (final row in r.rows) {
    for (var i = 0; i < row.length && i < widths.length; i++) {
      final l = row[i] is num ? 14 : row[i].toString().length;
      if (l > widths[i]) widths[i] = l;
    }
  }
  final b = StringBuffer('$_xh<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><cols>');
  for (var i = 0; i < widths.length; i++) {
    b.write('<col min="${i + 1}" max="${i + 1}" width="${(widths[i] + 3).clamp(8, 45)}" customWidth="1"/>');
  }
  b.write('</cols><sheetData>');
  for (var ri = 0; ri < rows.length; ri++) {
    b.write('<row r="${ri + 1}">');
    for (var ci = 0; ci < rows[ri].length; ci++) {
      final v = rows[ri][ci][0], s = rows[ri][ci][1];
      final ref = '${_col(ci)}${ri + 1}';
      if (v is num) {
        b.write('<c r="$ref" s="$s"><v>$v</v></c>');
      } else {
        b.write('<c r="$ref" s="$s" t="inlineStr"><is><t xml:space="preserve">${_esc(v.toString())}</t></is></c>');
      }
    }
    b.write('</row>');
  }
  b.write('</sheetData></worksheet>');
  return b.toString();
}

List<int> toXlsx(Rep r) {
  final all = [r, ...r.extra];
  final files = <String, List<int>>{};
  final ct = StringBuffer('$_xh<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>');
  final wb = StringBuffer('$_xh<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>');
  final rel = StringBuffer('$_xh<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">');
  for (var i = 0; i < all.length; i++) {
    final n = i + 1;
    var name = all[i].title.replaceAll(RegExp(r'[\\/?*\[\]:]'), ' ');
    if (name.length > 28) name = name.substring(0, 28);
    ct.write('<Override PartName="/xl/worksheets/sheet$n.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>');
    wb.write('<sheet name="${_esc(name)}${i == 0 ? '' : ' $n'}" sheetId="$n" r:id="rId$n"/>');
    rel.write('<Relationship Id="rId$n" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet$n.xml"/>');
    files['xl/worksheets/sheet$n.xml'] = utf8.encode(_sheetXml(all[i]));
  }
  rel.write('<Relationship Id="rId${all.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>');
  ct.write('</Types>');
  wb.write('</sheets></workbook>');
  final ordered = <String, List<int>>{
    '[Content_Types].xml': utf8.encode(ct.toString()),
    '_rels/.rels': utf8.encode('$_xh<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'),
    'xl/workbook.xml': utf8.encode(wb.toString()),
    'xl/_rels/workbook.xml.rels': utf8.encode(rel.toString()),
    'xl/styles.xml': utf8.encode(_styles),
    ...files,
  };
  return _zip(ordered);
}

Future<void> shareBytes(List<int> bytes, String name) async {
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/$name');
  await f.writeAsBytes(bytes);
  await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], subject: name));
}

Future<void> exportSheet(BuildContext c, String title, Rep Function(int) build, {List<String> scopes = const []}) =>
    showModalBottomSheet(context: c, showDragHandle: true, builder: (_) => _ExportSheet(title, build, scopes));

class _ExportSheet extends StatefulWidget {
  final String title;
  final Rep Function(int) build;
  final List<String> scopes;
  const _ExportSheet(this.title, this.build, this.scopes);
  @override
  State<_ExportSheet> createState() => _ExportState();
}

class _ExportState extends State<_ExportSheet> {
  int scope = 0;
  bool busy = false;

  Future<void> _go(String t) async {
    setState(() => busy = true);
    try {
      final r = widget.build(scope);
      final slug = '${norm(r.title).replaceAll(RegExp(r'[^a-z0-9]+'), '_')}_${todayIso()}';
      if (t == 'pdf') {
        await shareBytes(await toPdf(r), '$slug.pdf');
      } else if (t == 'xlsx') {
        await shareBytes(toXlsx(r), '$slug.xlsx');
      } else {
        await Clipboard.setData(ClipboardData(text: toText(r)));
        if (mounted) msg(context, 'Rapor metni panoya kopyalandı.');
      }
    } catch (e) {
      if (mounted) msg(context, 'Hata: $e');
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
            if (widget.scopes.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Wrap(spacing: 8, children: [
                  for (var i = 0; i < widget.scopes.length; i++)
                    ChoiceChip(label: Text(widget.scopes[i]), selected: scope == i, onSelected: (_) => setState(() => scope = i)),
                ]),
              ),
            const SizedBox(height: 6),
            if (busy) const LinearProgressIndicator(),
            ListTile(leading: const Icon(Icons.picture_as_pdf, color: red), title: const Text('PDF olarak paylaş / kaydet'), onTap: busy ? null : () => _go('pdf')),
            ListTile(leading: const Icon(Icons.table_chart, color: green), title: const Text('Excel (.xlsx) olarak paylaş / kaydet'), onTap: busy ? null : () => _go('xlsx')),
            ListTile(leading: const Icon(Icons.copy), title: const Text('Metin olarak kopyala (WhatsApp için)'), onTap: busy ? null : () => _go('txt')),
          ]),
        ),
      );
}

// ---- Rapor içerikleri ----
Rep repMusteri(int scope) {
  final l = S.cust.values.where((s) => s.durum != 'yok' && (scope == 0 || s.kalan > 0.5)).toList()..sort((a, b) => b.kalan.compareTo(a.kalan));
  final names = {...l.map((s) => norm(s.name))};
  final det = S.isler.where((r) => names.contains(norm(r['musteri'] ?? ''))).toList()
    ..sort((a, b) {
      final c = norm(a['musteri'] ?? '').compareTo(norm(b['musteri'] ?? ''));
      return c != 0 ? c : cmpDate(a, b);
    });
  return Rep(
    scope == 0 ? 'Müşteri Raporu' : 'Borçlu Müşteriler',
    ['Müşteri', 'İş', 'Borç', 'Alınan', 'Kalan', 'Durum', 'En eski ödenmemiş'],
    [for (final s in l) [s.name, s.n, s.borc, s.alinan, s.kalan, durumAd[s.durum]!, (s.oldest != null && s.kalan > 0.5) ? dshow(s.oldest) : '']],
    sub: '${l.length} müşteri · Tarih: ${dshow(todayIso())}',
    foot: ['TOPLAM', l.fold(0, (a, s) => a + s.n), l.fold(0.0, (a, s) => a + s.borc), l.fold(0.0, (a, s) => a + s.alinan), l.fold(0.0, (a, s) => a + s.kalan), '', ''],
    money: {2, 3, 4},
    extra: [
      Rep('Is detayi', ['Müşteri', 'Tarih', 'Makina', 'Miktar', 'Birim ücret', 'Borç', 'Alınan'],
          [for (final r in det) [r['musteri'] ?? '', dshow(r['tarih']), r['makina'] ?? '', r['miktar'] ?? '', toD(r['ucret']), borc(r), toD(r['alinan'])]],
          sub: 'Tüm iş ve tahsilat kayıtları', money: {4, 5, 6})
    ],
  );
}

Rep repGider(int m) {
  final l = S.byMonth(S.giderler, m);
  final g = groupBy(l, (r) => r['kalem'] ?? '-')..sort((a, b) => sum(b.l, (r) => toD(r['tutar'])).compareTo(sum(a.l, (r) => toD(r['tutar']))));
  final det = [...l]..sort((a, b) {
      final c = norm(a['kalem'] ?? '').compareTo(norm(b['kalem'] ?? ''));
      return c != 0 ? c : cmpDate(a, b);
    });
  return Rep(
    'Gider Raporu',
    ['Gider kalemi / kişi', 'Kayıt', 'Toplam'],
    [for (final x in g) [x.key, x.l.length, sum(x.l, (r) => toD(r['tutar']))]],
    sub: 'Dönem: ${aylar[m]} · ${l.length} kayıt',
    foot: ['TOPLAM', l.length, sum(l, (r) => toD(r['tutar']))],
    money: {2},
    extra: [
      Rep('Gider detayi', ['Tarih', 'Kalem', 'Tutar', 'Açıklama'], [for (final r in det) [dshow(r['tarih']), r['kalem'] ?? '', toD(r['tutar']), r['aciklama'] ?? '']], sub: 'Tüm gider kayıtları', money: {2})
    ],
  );
}

Rep repMakina(int m) {
  final l = S.makinaStat(m).where((s) => s.active).toList();
  return Rep(
    'Makina Raporu',
    ['Makina', 'Çalışma', 'Mazot L', 'L/birim', 'Gelir', 'Mazot ₺', 'Kâr'],
    [for (final s in l) [s.name, s.calisma, s.litre, s.lPerUnit, s.gelir, s.mazotTl, s.kar]],
    sub: 'Dönem: ${aylar[m]}',
    foot: ['TOPLAM', '', l.fold(0.0, (a, s) => a + s.litre), '', l.fold(0.0, (a, s) => a + s.gelir), l.fold(0.0, (a, s) => a + s.mazotTl), l.fold(0.0, (a, s) => a + s.kar)],
    money: {4, 5, 6},
  );
}

Rep repEkstre(String name) {
  final l = S.isler.where((r) => norm(r['musteri'] ?? '') == norm(name)).toList()..sort(cmpDate);
  var bak = 0.0;
  final rows = <List<Object>>[];
  for (final r in l) {
    bak += borc(r) - toD(r['alinan']);
    rows.add([dshow(r['tarih']), r['makina'] ?? '', r['miktar'] ?? '', toD(r['ucret']), borc(r), toD(r['alinan']), bak]);
  }
  final s = S.cust[norm(name)];
  return Rep('Ekstre - $name', ['Tarih', 'Makina', 'Miktar', 'Birim ücret', 'Borç', 'Alınan', 'Bakiye'], rows,
      sub: 'Durum: ${durumAd[s?.durum ?? 'yok']} · Kalan: ${tl(s?.kalan ?? 0, 'TL')} · ${dshow(todayIso())}',
      foot: ['TOPLAM', '', '', '', s?.borc ?? 0, s?.alinan ?? 0, s?.kalan ?? 0],
      money: {3, 4, 5, 6});
}

// ============================ GRUPLAMA ALTYAPISI ============================
class Grp {
  final String key;
  final List<R> l;
  Grp(this.key, this.l);
  String get last => l.fold('', (a, r) => (r['tarih'] ?? '').compareTo(a) > 0 ? (r['tarih'] ?? '') : a);
}

List<Grp> groupBy(List<R> l, String Function(R) kf) {
  final m = <String, List<R>>{}, names = <String, String>{};
  for (final r in l) {
    final k = kf(r).trim().isEmpty ? 'Belirtilmemiş' : kf(r).trim();
    final n = norm(k);
    names.putIfAbsent(n, () => k);
    (m[n] ??= []).add(r);
  }
  return [for (final e in m.entries) Grp(names[e.key]!, e.value)];
}

class SortOpt {
  final String label;
  final int Function(Grp, Grp) cmp;
  SortOpt(this.label, this.cmp);
}

class GCfg {
  final String title, selLabel;
  final List<R> Function() items;
  final String Function(R) keyOf;
  final List<String> Function() allKeys;
  final List<SortOpt> sorts;
  final Widget Function(BuildContext, Grp) card;
  final Widget Function(BuildContext, R) rec;
  final Widget Function(List<R>) summary;
  final String Function(List<R>) monthSum;
  final void Function(BuildContext, String?) onAdd;
  GCfg({required this.title, required this.selLabel, required this.items, required this.keyOf, required this.allKeys, required this.sorts, required this.card, required this.rec, required this.summary, required this.monthSum, required this.onAdd});
}

List<Widget> detailRows(BuildContext c, GCfg cfg, List<R> l) {
  final s = [...l]..sort((a, b) => cmpDate(b, a));
  final out = <Widget>[];
  String? cur;
  for (final r in s) {
    final t = r['tarih'] ?? '';
    final m = t.length >= 7 ? t.substring(0, 7) : '';
    if (m != cur) {
      cur = m;
      final grp = s.where((x) => (x['tarih'] ?? '').startsWith(m)).toList();
      final mi = int.tryParse(m.length >= 7 ? m.substring(5, 7) : '') ?? 0;
      out.add(Padding(
        padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
        child: Row(children: [
          Text('${aylar[mi]} ${m.length >= 4 ? m.substring(0, 4) : ''}'.toUpperCase(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: grey, letterSpacing: .5)),
          const Spacer(),
          Text('${grp.length} kayıt · ${cfg.monthSum(grp)}', style: const TextStyle(fontSize: 12, color: grey)),
        ]),
      ));
    }
    out.add(cfg.rec(c, r));
  }
  return out;
}

class GroupView extends StatefulWidget {
  final GCfg cfg;
  const GroupView(this.cfg, {super.key});
  @override
  State<GroupView> createState() => _GVState();
}

class _GVState extends State<GroupView> {
  String q = '';
  int sort = 0;
  String? sel;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: Listenable.merge([S, ayF]),
      builder: (c, _) {
        final cfg = widget.cfg;
        final all = cfg.items();
        var groups = groupBy(all, cfg.keyOf);
        final k = norm(q);
        if (k.isNotEmpty) {
          groups = groups.where((g) => norm(g.key).contains(k) || g.l.any((r) => r.values.any((v) => norm(v).contains(k)) || norm(dshow(r['tarih'])).contains(k))).toList();
        }
        groups.sort(cfg.sorts[sort].cmp);
        Grp? sg;
        if (sel != null) {
          for (final g in groupBy(all, cfg.keyOf)) {
            if (norm(g.key) == norm(sel!)) sg = g;
          }
        }
        return Scaffold(
          appBar: AppBar(title: Text(cfg.title), actions: const [AyDrop()]),
          body: Column(children: [
            Padding(padding: const EdgeInsets.fromLTRB(12, 10, 12, 6), child: searchBox((v) => setState(() => q = v), 'Ara…')),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Material(
                color: sel == null ? Colors.white : amber.withAlpha(40),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: line)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () async {
                    final v = await pickKey(c, cfg.selLabel, cfg.allKeys(), sel);
                    if (v != null) setState(() => sel = v.isEmpty ? null : v);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(children: [
                      Icon(Icons.filter_alt_outlined, color: sel == null ? grey : navy),
                      const SizedBox(width: 8),
                      Expanded(child: Text(sel ?? '${cfg.selLabel}: Tümü', style: TextStyle(fontWeight: FontWeight.w600, color: sel == null ? grey : navy), overflow: TextOverflow.ellipsis)),
                      if (sel != null) InkWell(onTap: () => setState(() => sel = null), child: const Padding(padding: EdgeInsets.all(2), child: Icon(Icons.close, size: 20)))
                      else const Icon(Icons.arrow_drop_down, color: grey),
                    ]),
                  ),
                ),
              ),
            ),
            if (sel == null && cfg.sorts.length > 1)
              SizedBox(
                height: 40,
                child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
                  for (var i = 0; i < cfg.sorts.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(label: Text(cfg.sorts[i].label), selected: sort == i, onSelected: (_) => setState(() => sort = i)),
                    ),
                ]),
              ),
            Expanded(
              child: ListView(padding: const EdgeInsets.fromLTRB(12, 6, 12, 90), children: [
                if (sel == null) ...[
                  cfg.summary(all),
                  const SizedBox(height: 10),
                  if (groups.isEmpty) const Padding(padding: EdgeInsets.all(40), child: Center(child: Text('Kayıt bulunamadı'))),
                  for (final g in groups) cfg.card(c, g),
                ] else ...[
                  if (sg == null) const Padding(padding: EdgeInsets.all(40), child: Center(child: Text('Bu dönemde kayıt yok'))),
                  if (sg != null) ...[cfg.summary(sg.l), ...detailRows(c, cfg, sg.l)],
                ],
              ]),
            ),
          ]),
          floatingActionButton: FloatingActionButton(onPressed: () => cfg.onAdd(c, sel), child: const Icon(Icons.add)),
        );
      });
}

class GroupDetailPage extends StatelessWidget {
  final GCfg cfg;
  final String keyName;
  const GroupDetailPage(this.cfg, this.keyName, {super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: Listenable.merge([S, ayF]),
      builder: (c, _) {
        final l = cfg.items().where((r) => norm(cfg.keyOf(r)) == norm(keyName)).toList();
        return Scaffold(
          appBar: AppBar(title: Text(keyName, overflow: TextOverflow.ellipsis), actions: const [AyDrop()]),
          body: ListView(padding: const EdgeInsets.fromLTRB(12, 10, 12, 90), children: [
            cfg.summary(l),
            const SizedBox(height: 4),
            if (l.isEmpty) const Padding(padding: EdgeInsets.all(40), child: Center(child: Text('Bu dönemde kayıt yok'))),
            ...detailRows(c, cfg, l),
          ]),
          floatingActionButton: FloatingActionButton(onPressed: () => cfg.onAdd(c, keyName), child: const Icon(Icons.add)),
        );
      });
}

// ============================ İŞLER ============================
Widget jobRec(BuildContext c, R r) {
  final b = borc(r), a = toD(r['alinan']), k = b - a;
  final tah = b == 0 && a > 0;
  return Box(
    pad: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    bottom: 6,
    onTap: () => editRec(c, S.isler, tah ? 'tahsilat' : 'iş', tah ? tahsilatFl() : isFl(), rec: r),
    child: Row(children: [
      Icon(tah ? Icons.south_west : Icons.construction, color: tah ? green : navy, size: 20),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tah ? 'Tahsilat' : '${r['makina'] ?? ''} · ${r['miktar'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w600)),
          Text('${dshow(r['tarih'])}${(r['musteri'] ?? '').isEmpty ? '' : ' · ${r['musteri']}'}${(r['aciklama'] ?? '').isEmpty || tah ? '' : '\n${r['aciklama']}'}', style: const TextStyle(fontSize: 12, color: grey)),
        ]),
      ),
      if (tah) Text('+${tl(a)}', style: const TextStyle(fontWeight: FontWeight.w700, color: green)) else two(tl(b), k.abs() < 0.5 ? 'ödendi' : 'kalan ${tl(k)}', bc: k > 0.5 ? red : green),
    ]),
  );
}

Widget _sumRow(List<Widget> w) => Box(child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: w));

class IslerTab extends StatelessWidget {
  IslerTab({super.key});
  final cfg = GCfg(
    title: 'İşler',
    selLabel: 'Müşteri seç',
    items: () => S.byMonth(S.isler, ayF.value).toList(),
    keyOf: (r) => r['musteri'] ?? '',
    allKeys: () => [...S.musteriler]..sort((a, b) => norm(a).compareTo(norm(b))),
    sorts: [
      SortOpt('En çok borç', (a, b) => (S.cust[norm(b.key)]?.kalan ?? 0).compareTo(S.cust[norm(a.key)]?.kalan ?? 0)),
      SortOpt('En eski ödenmemiş', (a, b) {
        final x = (S.cust[norm(a.key)]?.kalan ?? 0) > 0.5 ? S.cust[norm(a.key)]?.oldest : null;
        final y = (S.cust[norm(b.key)]?.kalan ?? 0) > 0.5 ? S.cust[norm(b.key)]?.oldest : null;
        if (x == null && y == null) return 0;
        if (x == null) return 1;
        if (y == null) return -1;
        return x.compareTo(y);
      }),
      SortOpt('Son işlem', (a, b) => b.last.compareTo(a.last)),
      SortOpt('A–Z', (a, b) => norm(a.key).compareTo(norm(b.key))),
    ],
    card: (c, g) => musteriCard(c, g.key, sub: '${g.l.length} kayıt · dönem borcu ${tl(sum(g.l, borc))}'),
    rec: jobRec,
    summary: (l) => _sumRow([
      two(tl(sum(l, borc)), 'Borç'),
      two(tl(sum(l, (r) => toD(r['alinan']))), 'Alınan'),
      two(tl(sum(l, borc) - sum(l, (r) => toD(r['alinan']))), 'Kalan', ac: red),
    ]),
    monthSum: (l) => 'borç ${tl(sum(l, borc))}',
    onAdd: (c, k) => editRec(c, S.isler, 'iş', isFl(), defaults: k == null ? null : {'musteri': k}),
  );
  @override
  Widget build(BuildContext context) => GroupView(cfg);
}

Widget musteriCard(BuildContext c, String name, {String? sub}) {
  final s = S.cust[norm(name)] ?? CStat(name);
  final rk = S.rank(name);
  final d = s.durum;
  return Box(
    onTap: () => push(c, MusteriDetay(name)),
    color: rk >= 0 ? goldBg : null,
    border: rk >= 0 ? gold : null,
    child: Row(children: [
      Avatar(name),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
            if (rk >= 0) const SizedBox(width: 6),
            if (rk >= 0) Pill('★ ${rk + 1}', gold),
          ]),
          const SizedBox(height: 2),
          Text(sub ?? 'Borç ${tl(s.borc)} · Alınan ${tl(s.alinan)}', style: const TextStyle(fontSize: 12, color: grey)),
          const SizedBox(height: 4),
          Wrap(spacing: 6, runSpacing: 4, children: [Pill(durumAd[d]!, durumRenk[d]!), agePill(s)]),
        ]),
      ),
      const SizedBox(width: 8),
      two(tl(s.kalan), 'kalan', ac: s.kalan > 0.5 ? red : green),
    ]),
  );
}

// ============================ GİDER ============================
class GiderTab extends StatelessWidget {
  GiderTab({super.key});
  late final GCfg cfg = GCfg(
    title: 'Gider',
    selLabel: 'Kalem / kişi seç',
    items: () => S.byMonth(S.giderler, ayF.value).toList(),
    keyOf: (r) => r['kalem'] ?? '',
    allKeys: () => ({...S.giderler.map((e) => (e['kalem'] ?? '').trim())}.where((e) => e.isNotEmpty).toList())..sort((a, b) => norm(a).compareTo(norm(b))),
    sorts: [
      SortOpt('En yüksek tutar', (a, b) => sum(b.l, (r) => toD(r['tutar'])).compareTo(sum(a.l, (r) => toD(r['tutar'])))),
      SortOpt('En çok kayıt', (a, b) => b.l.length.compareTo(a.l.length)),
      SortOpt('Son kayıt', (a, b) => b.last.compareTo(a.last)),
      SortOpt('A–Z', (a, b) => norm(a.key).compareTo(norm(b.key))),
    ],
    card: (c, g) => Box(
      onTap: () => push(c, GroupDetailPage(cfg, g.key)),
      child: Row(children: [
        Avatar(g.key),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(g.key, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            Text('${g.l.length} kayıt · son: ${dshow(g.last)}', style: const TextStyle(fontSize: 12, color: grey)),
          ]),
        ),
        Text(tl(sum(g.l, (r) => toD(r['tutar']))), style: const TextStyle(fontWeight: FontWeight.w700, color: red)),
        const Icon(Icons.chevron_right, color: grey),
      ]),
    ),
    rec: (c, r) => Box(
      pad: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      bottom: 6,
      onTap: () => editRec(c, S.giderler, 'gider', giderFl(), rec: r),
      child: Row(children: [
        const Icon(Icons.receipt_long, color: red, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(dshow(r['tarih']), style: const TextStyle(fontWeight: FontWeight.w600)),
            if ((r['aciklama'] ?? '').isNotEmpty) Text(r['aciklama']!, style: const TextStyle(fontSize: 12, color: grey)),
          ]),
        ),
        Text(tl(toD(r['tutar'])), style: const TextStyle(fontWeight: FontWeight.w700, color: red)),
      ]),
    ),
    summary: (l) => _sumRow([two(tl(sum(l, (r) => toD(r['tutar']))), 'Toplam gider', ac: red), two('${l.length}', 'kayıt'), two('${groupBy(l, (r) => r['kalem'] ?? '').length}', 'kalem')]),
    monthSum: (l) => tl(sum(l, (r) => toD(r['tutar']))),
    onAdd: (c, k) => editRec(c, S.giderler, 'gider', giderFl(), defaults: k == null ? null : {'kalem': k}),
  );
  @override
  Widget build(BuildContext context) => GroupView(cfg);
}

// ============================ MAZOT ============================
String mKey(R r) => r['tur'] == 'giren' ? 'Depo girişleri' : (r['tur'] == 'alim' ? 'Dışarıdan alımlar' : ((r['makina'] ?? '').trim().isEmpty ? 'Makina belirtilmemiş' : r['makina']!.trim()));

class MazotTab extends StatelessWidget {
  MazotTab({super.key});
  late final GCfg cfg = GCfg(
    title: 'Mazot',
    selLabel: 'Makina seç',
    items: () => S.byMonth(S.mazot, ayF.value).toList(),
    keyOf: mKey,
    allKeys: () => ['Depo girişleri', 'Dışarıdan alımlar', ...S.makinalar],
    sorts: [
      SortOpt('En çok litre', (a, b) => sum(b.l, (r) => toD(r['litre'])).compareTo(sum(a.l, (r) => toD(r['litre'])))),
      SortOpt('Son kayıt', (a, b) => b.last.compareTo(a.last)),
      SortOpt('A–Z', (a, b) => norm(a.key).compareTo(norm(b.key))),
    ],
    card: (c, g) {
      final lit = sum(g.l, (r) => toD(r['litre']));
      final out = g.l.every((r) => r['tur'] == 'cikan');
      final tut = out ? lit * S.avgPrice : sum(g.l, (r) => toD(r['tutar']));
      return Box(
        onTap: () => push(c, GroupDetailPage(cfg, g.key)),
        child: Row(children: [
          Avatar(g.key, icon: g.key == 'Depo girişleri' ? Icons.archive_outlined : (g.key == 'Dışarıdan alımlar' ? Icons.shopping_cart_outlined : Icons.local_gas_station)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(g.key, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              Text('${g.l.length} kayıt · son: ${dshow(g.last)}', style: const TextStyle(fontSize: 12, color: grey)),
            ]),
          ),
          two('${f2(lit)} L', tut > 0 ? (out ? '≈ ${tl(tut)}' : tl(tut)) : ''),
          const Icon(Icons.chevron_right, color: grey),
        ]),
      );
    },
    rec: (c, r) => Box(
      pad: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      bottom: 6,
      onTap: () => editRec(c, S.mazot, 'mazot kaydı', mazotFl(), rec: r),
      child: Row(children: [
        Icon(r['tur'] == 'giren' ? Icons.south_west : (r['tur'] == 'alim' ? Icons.shopping_cart_outlined : Icons.north_east), color: r['tur'] == 'cikan' ? orange : green, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(dshow(r['tarih']), style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(r['tur'] == 'giren' ? 'Depoya giriş' : (r['tur'] == 'alim' ? 'Dışarıdan alım' : 'Makinaya yakıt'), style: const TextStyle(fontSize: 12, color: grey)),
          ]),
        ),
        two('${r['litre'] ?? '0'} L', toD(r['tutar']) > 0 ? tl(toD(r['tutar'])) : ''),
      ]),
    ),
    summary: (l) => _sumRow([
      two('${f2(S.depo)} L', 'Depoda (toplam)'),
      two('${f2(sum(l.where((r) => r['tur'] == 'giren'), (r) => toD(r['litre'])))} L', 'Giren'),
      two('${f2(sum(l.where((r) => r['tur'] == 'cikan'), (r) => toD(r['litre'])))} L', 'Çıkan'),
    ]),
    monthSum: (l) => '${f2(sum(l, (r) => toD(r['litre'])))} L',
    onAdd: (c, k) => editRec(c, S.mazot, 'mazot kaydı', mazotFl(),
        defaults: k == 'Depo girişleri' ? {'tur': 'giren'} : (k == 'Dışarıdan alımlar' ? {'tur': 'alim'} : {'tur': 'cikan', if (k != null && k != 'Makina belirtilmemiş') 'makina': k})),
  );
  @override
  Widget build(BuildContext context) => GroupView(cfg);
}

// ============================ MÜŞTERİ ============================
class MusteriTab extends StatefulWidget {
  const MusteriTab({super.key});
  @override
  State<MusteriTab> createState() => _MusteriState();
}

class _MusteriState extends State<MusteriTab> {
  String q = '', seg = 'hic';
  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: S,
      builder: (c, _) {
        final all = S.cust.values.toList();
        int cnt(String d) => all.where((s) => s.durum == d).length;
        final k = norm(q);
        final l = (k.isNotEmpty ? all.where((s) => norm(s.name).contains(k)) : all.where((s) => s.durum == seg)).toList();
        l.sort((a, b) => seg == 'tam' && k.isEmpty ? b.borc.compareTo(a.borc) : b.kalan.compareTo(a.kalan));
        final segs = ['hic', 'kismen', 'tam', if (cnt('yok') > 0) 'yok'];
        final y = S.year;
        return Scaffold(
          appBar: AppBar(title: const Text('Müşteriler')),
          body: Column(children: [
            Padding(padding: const EdgeInsets.fromLTRB(12, 10, 12, 6), child: searchBox((v) => setState(() => q = v), 'Müşteri ara…')),
            SizedBox(
              height: 42,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
                for (final d in segs)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      selectedColor: durumRenk[d]!.withAlpha(45),
                      avatar: CircleAvatar(radius: 5, backgroundColor: durumRenk[d]),
                      label: Text('${durumAd[d]} (${cnt(d)})', style: const TextStyle(fontWeight: FontWeight.w600)),
                      selected: seg == d && k.isEmpty,
                      onSelected: (_) => setState(() {
                        seg = d;
                        q = '';
                      }),
                    ),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(children: [
                const Icon(Icons.star, size: 14, color: gold),
                const SizedBox(width: 4),
                Expanded(child: Text('Altın çerçeve: $y yılında en çok iş yapılan 5 müşteri', style: const TextStyle(fontSize: 12, color: grey))),
              ]),
            ),
            Expanded(
              child: l.isEmpty
                  ? const Center(child: Text('Bu grupta müşteri yok'))
                  : ListView.builder(padding: const EdgeInsets.fromLTRB(12, 4, 12, 90), itemCount: l.length, itemBuilder: (c, i) => musteriCard(c, l[i].name)),
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
        final l = S.isler.where((r) => norm(r['musteri'] ?? '') == norm(name)).toList();
        final s = S.cust[norm(name)] ?? CStat(name);
        final rk = S.rank(name);
        final cfg = GCfg(
            title: name, selLabel: '', items: () => l, keyOf: (r) => name, allKeys: () => [], sorts: [], card: (c, g) => const SizedBox(), rec: jobRec, summary: (x) => const SizedBox(),
            monthSum: (x) => 'borç ${tl(sum(x, borc))} · alınan ${tl(sum(x, (r) => toD(r['alinan'])))}', onAdd: (c, k) {});
        return Scaffold(
          appBar: AppBar(title: Text(name, overflow: TextOverflow.ellipsis), actions: [
            IconButton(icon: const Icon(Icons.ios_share), tooltip: 'Ekstre', onPressed: () => exportSheet(c, 'Ekstre - $name', (_) => repEkstre(name))),
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'r') {
                  final n = await askName(c, 'Müşteri adı', name);
                  if (n == null || n.isEmpty) return;
                  for (final r in l) {
                    r['musteri'] = n;
                  }
                  final i = S.musteriler.indexWhere((x) => norm(x) == norm(name));
                  if (i >= 0) S.musteriler[i] = n;
                  S.commit();
                  if (c.mounted) Navigator.pop(c);
                } else if (l.isNotEmpty) {
                  msg(c, 'Bu müşterinin ${l.length} kaydı var. Önce kayıtları silin veya başka müşteriye taşıyın.');
                } else {
                  S.musteriler.removeWhere((x) => norm(x) == norm(name));
                  S.commit();
                  Navigator.pop(c);
                }
              },
              itemBuilder: (_) => const [PopupMenuItem(value: 'r', child: Text('Adını değiştir')), PopupMenuItem(value: 'd', child: Text('Müşteriyi sil'))],
            ),
          ]),
          body: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 40), children: [
            Box(
              color: rk >= 0 ? goldBg : null,
              border: rk >= 0 ? gold : null,
              child: Row(children: [
                Avatar(name),
                const SizedBox(width: 12),
                Expanded(child: Text(name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17))),
                Wrap(spacing: 6, children: [if (rk >= 0) Pill('★ ${rk + 1}. büyük müşteri', gold), Pill(durumAd[s.durum]!, durumRenk[s.durum]!)]),
              ]),
            ),
            Row(children: [
              Expanded(child: StatCard('Borç', tl(s.borc), icon: Icons.work_outline)),
              const SizedBox(width: 8),
              Expanded(child: StatCard('Alınan', tl(s.alinan), color: green, icon: Icons.south_west)),
              const SizedBox(width: 8),
              Expanded(child: StatCard('Kalan', tl(s.kalan), color: s.kalan > 0.5 ? red : green, icon: Icons.hourglass_bottom)),
            ]),
            const SizedBox(height: 10),
            if (s.kalan > 0.5 && s.oldest != null) Align(alignment: Alignment.centerLeft, child: agePill(s)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: FilledButton.icon(onPressed: () => editRec(c, S.isler, 'tahsilat', tahsilatFl(), defaults: {'musteri': name, 'aciklama': 'Tahsilat'}), icon: const Icon(Icons.payments), label: const Text('Tahsilat'))),
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton.icon(onPressed: () => editRec(c, S.isler, 'iş', isFl(), defaults: {'musteri': name}), icon: const Icon(Icons.add), label: const Text('İş ekle'))),
              const SizedBox(width: 8),
              IconButton.outlined(
                tooltip: 'Hatırlatma mesajını kopyala',
                onPressed: () {
                  Clipboard.setData(ClipboardData(
                      text: 'Merhaba $name, ${s.oldest != null ? '${dshow(s.oldest)} tarihli işlerimizden başlayarak ' : ''}toplam ${tl(s.kalan)} bakiyeniz bulunmaktadır. Müsait olduğunuzda ödemenizi rica ederiz. Teşekkürler.'));
                  msg(c, 'Hatırlatma mesajı kopyalandı, WhatsApp\'a yapıştırabilirsiniz.');
                },
                icon: const Icon(Icons.chat),
              ),
            ]),
            ...detailRows(c, cfg, l),
          ]),
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
        final l = S.makinaStat(ayF.value)..sort((a, b) => b.gelir.compareTo(a.gelir));
        return Scaffold(
          appBar: AppBar(title: const Text('Makinalar'), actions: const [AyDrop()]),
          body: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 90), children: [
            for (final s in l)
              Box(
                onTap: () => push(c, MakinaDetay(s.name)),
                child: Row(children: [
                  Avatar(s.name, icon: Icons.precision_manufacturing),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(s.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                      Text('${s.active ? s.calisma : 'Kayıt yok'} · ${f2(s.litre)} L yakıt', style: const TextStyle(fontSize: 12, color: grey)),
                    ]),
                  ),
                  two(tl(s.gelir), 'kâr ${tl(s.kar)}', bc: signC(s.kar)),
                  const Icon(Icons.chevron_right, color: grey),
                ]),
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
}

class MakinaDetay extends StatelessWidget {
  final String name;
  const MakinaDetay(this.name, {super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: Listenable.merge([S, ayF]),
      builder: (c, _) {
        final k = norm(name);
        final jobs = S.byMonth(S.isler, ayF.value).where((r) => norm(r['makina'] ?? '') == k).toList();
        final fuel = S.byMonth(S.mazot, ayF.value).where((r) => r['tur'] == 'cikan' && norm(r['makina'] ?? '') == k).toList();
        final st = S.makinaStat(ayF.value).firstWhere((s) => norm(s.name) == k, orElse: () => MStat(name));
        final jc = GCfg(title: '', selLabel: '', items: () => jobs, keyOf: (r) => name, allKeys: () => [], sorts: [], card: (c, g) => const SizedBox(), rec: jobRec, summary: (x) => const SizedBox(), monthSum: (x) => tl(sum(x, borc)), onAdd: (c, k) {});
        final fc = GCfg(
            title: '', selLabel: '', items: () => fuel, keyOf: (r) => name, allKeys: () => [], sorts: [], card: (c, g) => const SizedBox(), summary: (x) => const SizedBox(), monthSum: (x) => '${f2(sum(x, (r) => toD(r['litre'])))} L', onAdd: (c, k) {},
            rec: (c, r) => Box(
                  pad: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  bottom: 6,
                  onTap: () => editRec(c, S.mazot, 'mazot kaydı', mazotFl(), rec: r),
                  child: Row(children: [const Icon(Icons.local_gas_station, color: orange, size: 20), const SizedBox(width: 10), Expanded(child: Text(dshow(r['tarih']))), Text('${r['litre'] ?? '0'} L', style: const TextStyle(fontWeight: FontWeight.w700))]),
                ));
        return Scaffold(
          appBar: AppBar(title: Text(name), actions: [
            const AyDrop(),
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'r') {
                  final n = await askName(c, 'Makina adı', name);
                  if (n == null || n.isEmpty) return;
                  for (final r in [...S.isler, ...S.mazot]) {
                    if (norm(r['makina'] ?? '') == k) r['makina'] = n;
                  }
                  final i = S.makinalar.indexWhere((e) => norm(e) == k);
                  if (i >= 0) S.makinalar[i] = n;
                  S.commit();
                  if (c.mounted) Navigator.pop(c);
                } else {
                  S.makinalar.removeWhere((e) => norm(e) == k);
                  S.commit();
                  Navigator.pop(c);
                }
              },
              itemBuilder: (_) => const [PopupMenuItem(value: 'r', child: Text('Adını değiştir')), PopupMenuItem(value: 'd', child: Text('Listeden sil (kayıtlar kalır)'))],
            ),
          ]),
          body: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 90), children: [
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 2.1,
              children: [
                StatCard('Çalışma', st.active ? st.calisma : '-', icon: Icons.timer_outlined),
                StatCard('Gelir', tl(st.gelir), icon: Icons.trending_up),
                StatCard('Yakıt', '${f2(st.litre)} L', icon: Icons.local_gas_station),
                StatCard('Kâr', tl(st.kar), color: signC(st.kar), icon: Icons.account_balance_wallet_outlined),
              ],
            ),
            secTitle('Yakıt çıkışları'),
            if (fuel.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('Kayıt yok', style: TextStyle(color: grey))),
            ...detailRows(c, fc, fuel),
            secTitle('İş kayıtları'),
            if (jobs.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('Kayıt yok', style: TextStyle(color: grey))),
            ...detailRows(c, jc, jobs),
          ]),
          floatingActionButton: FloatingActionButton(
            onPressed: () => showModalBottomSheet(
                context: c,
                builder: (x) => SafeArea(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        ListTile(leading: const Icon(Icons.construction), title: const Text('İş ekle'), onTap: () {
                          Navigator.pop(x);
                          editRec(c, S.isler, 'iş', isFl(), defaults: {'makina': name});
                        }),
                        ListTile(leading: const Icon(Icons.local_gas_station), title: const Text('Yakıt çıkışı ekle'), onTap: () {
                          Navigator.pop(x);
                          editRec(c, S.mazot, 'mazot kaydı', mazotFl(), defaults: {'tur': 'cikan', 'makina': name});
                        }),
                      ]),
                    )),
            child: const Icon(Icons.add),
          ),
        );
      });
}

// ============================ ÖZET ============================
class OzetTab extends StatelessWidget {
  const OzetTab({super.key});

  Widget _chart() {
    final b = List.generate(12, (i) => sum(S.isler.where((r) => mon(r) == i + 1 && (r['tarih'] ?? '').startsWith(S.year)), borc));
    final g = List.generate(12, (i) => sum(S.giderler.where((r) => mon(r) == i + 1 && (r['tarih'] ?? '').startsWith(S.year)), (r) => toD(r['tutar'])));
    final mx = [...b, ...g].fold(0.0, (a, v) => v > a ? v : a);
    Widget bar(double v, Color c) => Container(width: 8, height: mx == 0 ? 0 : 100 * v / mx, decoration: BoxDecoration(color: c, borderRadius: const BorderRadius.vertical(top: Radius.circular(3))));
    return Box(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Text('Aylık iş ve gider', style: TextStyle(fontWeight: FontWeight.w700))),
          const CircleAvatar(radius: 4, backgroundColor: blue),
          const Text('  İş   ', style: TextStyle(fontSize: 12, color: grey)),
          const CircleAvatar(radius: 4, backgroundColor: red),
          const Text('  Gider', style: TextStyle(fontSize: 12, color: grey)),
        ]),
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (var i = 0; i < 12; i++)
            Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(height: 100, child: Row(crossAxisAlignment: CrossAxisAlignment.end, mainAxisAlignment: MainAxisAlignment.center, children: [bar(b[i], blue), const SizedBox(width: 2), bar(g[i], red)])),
                const SizedBox(height: 4),
                Text(aylar[i + 1].substring(0, 3), style: const TextStyle(fontSize: 9, color: grey)),
              ]),
            ),
        ]),
      ]),
    );
  }

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
        final borclu = (S.cust.values.where((s) => s.kalan > 0.5).toList()..sort((a, b) => b.kalan.compareTo(a.kalan))).take(5).toList();
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
              childAspectRatio: 1.7,
              children: [
                StatCard('Toplam iş (borç)', tl(borcT), icon: Icons.work_outline),
                StatCard('Alınan', tl(alinan), color: green, icon: Icons.south_west),
                StatCard('Müşterilerde kalan (tüm zamanlar)', tl(kalanAll), color: red, icon: Icons.hourglass_bottom),
                StatCard('Depoda mazot', '${f2(S.depo)} L', icon: Icons.local_gas_station),
                StatCard('Giderler', tl(gider), color: red, icon: Icons.receipt_long),
                StatCard('Mazot alımı (fiyatı girilenler)', tl(alim), color: red, icon: Icons.shopping_cart_outlined),
                StatCard('Net kâr (iş – gider – mazot)', tl(net), color: signC(net), icon: Icons.trending_up),
                StatCard('Kasa (alınan – gider – mazot)', tl(kasa), color: signC(kasa), icon: Icons.account_balance_wallet_outlined),
              ],
            ),
            secTitle('Raporlar (PDF / Excel)'),
            Box(
              child: Row(children: [
                for (final e in [
                  ['Müşteri\nraporu', 'm', Icons.groups],
                  ['Gider\nraporu', 'g', Icons.receipt_long],
                  ['Makina\nraporu', 'k', Icons.precision_manufacturing]
                ])
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: amber, foregroundColor: Colors.white, minimumSize: const Size(0, 70), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                        onPressed: () {
                          if (e[1] == 'm') {
                            exportSheet(c, 'Müşteri raporu', repMusteri, scopes: const ['Tüm müşteriler', 'Sadece borçlular']);
                          } else if (e[1] == 'g') {
                            exportSheet(c, 'Gider raporu (${aylar[m]})', (_) => repGider(m));
                          } else {
                            exportSheet(c, 'Makina raporu (${aylar[m]})', (_) => repMakina(m));
                          }
                        },
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(e[2] as IconData, size: 20), const SizedBox(height: 4), Text(e[0] as String, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12))]),
                      ),
                    ),
                  ),
              ]),
            ),
            secTitle('Aylık görünüm'),
            _chart(),
            secTitle('En çok borçlu 5 müşteri'),
            if (borclu.isEmpty) const Box(child: Text('Borçlu müşteri yok 🎉')),
            for (final s in borclu)
              Box(
                pad: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                bottom: 6,
                onTap: () => push(c, MusteriDetay(s.name)),
                child: Row(children: [
                  Avatar(s.name),
                  const SizedBox(width: 10),
                  Expanded(child: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
                  Text(tl(s.kalan), style: const TextStyle(fontWeight: FontWeight.w700, color: red)),
                ]),
              ),
            secTitle('${S.year} yılının en büyük 5 müşterisi'),
            for (var i = 0; i < S.top5.length; i++)
              Box(
                color: goldBg,
                border: gold,
                pad: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                bottom: 6,
                onTap: () => push(c, MusteriDetay(S.top5[i].name)),
                child: Row(children: [
                  Pill('★ ${i + 1}', gold),
                  const SizedBox(width: 10),
                  Expanded(child: Text(S.top5[i].name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
                  Text(tl(S.top5[i].yil), style: const TextStyle(fontWeight: FontWeight.w700)),
                ]),
              ),
            secTitle('Makina analizi'),
            Box(
              pad: EdgeInsets.zero,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columnSpacing: 18,
                  headingTextStyle: const TextStyle(fontWeight: FontWeight.w700, color: grey, fontSize: 12),
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
                        DataCell(Text(s.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                        DataCell(Text(s.calisma)),
                        DataCell(Text(f2(s.litre))),
                        DataCell(Text(f2(s.lPerUnit), style: const TextStyle(fontWeight: FontWeight.bold))),
                        DataCell(Text(tl(s.gelir, ''))),
                        DataCell(Text(tl(s.mazotTl, ''))),
                        DataCell(Text(tl(s.kar, ''), style: TextStyle(color: signC(s.kar), fontWeight: FontWeight.w600))),
                      ]),
                  ],
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('L/birim: litre ÷ (saat veya sefer). Mazot ₺ = litre × fiyatı girilmiş alımların ortalama litre fiyatı.', style: TextStyle(color: grey, fontSize: 12)),
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
}
