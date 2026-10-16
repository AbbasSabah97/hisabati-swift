import SwiftUI
import SQLite3
import UniformTypeIdentifiers

// ثوابت ومساعدات
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
let NOW = "CAST((julianday('now')-2440587.5)*86400000 AS INTEGER)"
let CATS = ["طعام", "سكن وإيجار", "مواصلات", "فواتير وخدمات", "صحة", "تعليم", "ترفيه", "ملابس", "أخرى"]
let SRC = ["الراتب", "مكافأة", "أعمال حرة", "أخرى"]
let MONTHS = ["كانون الثاني", "شباط", "آذار", "نيسان", "أيار", "حزيران", "تموز", "آب", "أيلول", "تشرين الأول", "تشرين الثاني", "كانون الأول"]
let indigo = Color(red: 0.26, green: 0.22, blue: 0.79)
let navy = Color(red: 0.12, green: 0.11, blue: 0.29)
let gold = Color(red: 0.83, green: 0.63, blue: 0.09)

let iso: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

func fmt(_ v: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = Locale(identifier: "en_US")
    f.maximumFractionDigits = 0
    return f.string(from: NSNumber(value: v)) ?? "0"
}

func parseNum(_ s: String) -> Double? {
    var t = s
    for (i, ch) in "٠١٢٣٤٥٦٧٨٩".enumerated() { t = t.replacingOccurrences(of: String(ch), with: String(i)) }
    t = t.replacingOccurrences(of: "٫", with: ".").replacingOccurrences(of: ",", with: "")
        .replacingOccurrences(of: "٬", with: "").replacingOccurrences(of: " ", with: "")
    if let v = Double(t), v > 0 { return v }
    return nil
}

func toI(_ v: Any) -> Int64 {
    if let i = v as? Int64 { return i }
    if let d = v as? Double { return Int64(d) }
    return 0
}

func toD(_ v: Any) -> Double {
    if let d = v as? Double { return d }
    if let i = v as? Int64 { return Double(i) }
    return 0
}

struct Rec: Identifiable {
    var id: Int64
    var d: String
    var c: String
    var a: Double
    var n: String
}

struct Row: Identifiable {
    let id: String
    let isInc: Bool
    let rec: Rec
}

struct FormInfo: Identifiable {
    let id = UUID()
    let isInc: Bool
    let rec: Rec?
}

// قاعدة البيانات SQLite المدمجة في نظام iOS (الملف: Documents/accounts.db)
final class Store: ObservableObject {
    @Published var inc: [Rec] = []
    @Published var exp: [Rec] = []
    @Published var bud: [String: Double] = [:]
    @Published var year = Calendar.current.component(.year, from: Date())
    @Published var month = Calendar.current.component(.month, from: Date())
    private var db: OpaquePointer?

    let path: String

    init() {
        path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("accounts.db").path
        openDB()
        reload()
    }

    func openDB() {
        sqlite3_open(path, &db)
        run("CREATE TABLE IF NOT EXISTS income(id INTEGER PRIMARY KEY AUTOINCREMENT, d TEXT, src TEXT, amount REAL, note TEXT)")
        run("CREATE TABLE IF NOT EXISTS expenses(id INTEGER PRIMARY KEY AUTOINCREMENT, d TEXT, cat TEXT, amount REAL, note TEXT)")
        run("CREATE TABLE IF NOT EXISTS budgets(cat TEXT PRIMARY KEY, lim REAL)")
        migrateSync()
    }

    // ===== المزامنة عبر ملف JSON في Google Drive (آخر تعديل يفوز) =====
    let syncTables: [(String, [String])] = [("income", ["d", "src", "amount", "note"]), ("expenses", ["d", "cat", "amount", "note"]), ("budgets", ["cat", "lim"])]

    // يضيف أعمدة uid/upd/del ومحفزات تحدّثها تلقائياً (مطابقة لنسخة الحاسوب)
    func migrateSync() {
        for (t, _) in syncTables {
            for (col, ddl) in [("uid", "TEXT"), ("upd", "INTEGER DEFAULT 0"), ("del", "INTEGER DEFAULT 0")] {
                run("ALTER TABLE \(t) ADD COLUMN \(col) \(ddl)")
            }
            let key = t == "budgets" ? "cat" : "lower(hex(randomblob(16)))"
            let nk = t == "budgets" ? "NEW.cat" : "lower(hex(randomblob(16)))"
            run("UPDATE \(t) SET uid=\(key) WHERE uid IS NULL")
            run("UPDATE \(t) SET upd=\(NOW) WHERE upd IS NULL OR upd=0")
            run("CREATE TRIGGER IF NOT EXISTS \(t)_ai AFTER INSERT ON \(t) WHEN NEW.uid IS NULL BEGIN UPDATE \(t) SET uid=\(nk), upd=\(NOW) WHERE rowid=NEW.rowid; END")
            run("CREATE TRIGGER IF NOT EXISTS \(t)_au AFTER UPDATE ON \(t) WHEN NEW.upd=OLD.upd BEGIN UPDATE \(t) SET upd=\(NOW) WHERE rowid=NEW.rowid; END")
        }
    }

    func applyRow(_ t: String, _ cols: [String], _ r: [String: Any]) {
        guard let uid = r["uid"] as? String, let up = (r["upd"] as? NSNumber)?.int64Value else { return }
        let del = (r["del"] as? NSNumber)?.int64Value ?? 0
        var vals: [Any] = []
        for c in cols {
            if let x = r[c] as? String { vals.append(x) }
            else if let n = r[c] as? NSNumber { vals.append(n.doubleValue) }
            else { vals.append("") }
        }
        let ex = rows("SELECT upd FROM \(t) WHERE uid=?", [uid])
        if let first = ex.first {
            if toI(first[0]) >= up { return }
            run("UPDATE \(t) SET \(cols.map { $0 + "=?" }.joined(separator: ",")),upd=?,del=? WHERE uid=?", vals + [up, del, uid])
        } else {
            run("INSERT INTO \(t)(uid,\(cols.joined(separator: ",")),upd,del) VALUES(\(Array(repeating: "?", count: cols.count + 3).joined(separator: ",")))", [uid] + vals + [up, del])
        }
    }

    func mergeAndExport(_ data: Data?) -> Data? {
        if let data = data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]] {
            for (t, cols) in syncTables { for r in obj[t] ?? [] { applyRow(t, cols, r) } }
        }
        var out: [String: [[String: Any]]] = [:]
        for (t, cols) in syncTables {
            let names = ["uid"] + cols + ["upd", "del"]
            out[t] = rows("SELECT \(names.joined(separator: ",")) FROM \(t)").map { (row: [Any]) -> [String: Any] in
                var d: [String: Any] = [:]
                for (i, n) in names.enumerated() { d[n] = row[i] }
                return d
            }
        }
        return try? JSONSerialization.data(withJSONObject: out)
    }

    func syncWith(_ url: URL) -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fc = NSFileCoordinator()
        var e1: NSError?
        var remote: Data?
        var readOK = false
        fc.coordinate(readingItemAt: url, options: [], error: &e1) { u in
            if let d = try? Data(contentsOf: u) { remote = d; readOK = true }
        }
        if !readOK { return "تعذّرت قراءة ملف المزامنة. تأكد أن تطبيق Google Drive مثبّت ومسجَّل الدخول، وأن الملف تم تنزيله." }
        guard let out = mergeAndExport(remote) else { return "تعذّر دمج البيانات." }
        var e2: NSError?
        var wrote = false
        fc.coordinate(writingItemAt: url, options: .forReplacing, error: &e2) { u in
            do { try out.write(to: u); wrote = true } catch {}
        }
        reload()
        return wrote ? "تمت المزامنة بنجاح ✓" : "تم دمج البيانات لكن تعذّر حفظ الملف في Drive."
    }

    // نسخة احتياطية: تُنسخ القاعدة إلى ملف مؤقت يُشارَك عبر قائمة المشاركة
    func backupFile() -> URL {
        let t = FileManager.default.temporaryDirectory.appendingPathComponent("accounts-\(iso.string(from: Date())).db")
        try? FileManager.default.removeItem(at: t)
        try? FileManager.default.copyItem(atPath: path, toPath: t.path)
        return t
    }

    // استعادة: يستبدل ملف القاعدة الحالي بالملف المختار
    func restore(from src: URL) -> Bool {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        sqlite3_close(db)
        db = nil
        var ok = false
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: path + ".restore")
        try? fm.removeItem(at: tmp)
        do {
            try fm.copyItem(at: src, to: tmp)
            try? fm.removeItem(atPath: path)
            try fm.moveItem(at: tmp, to: URL(fileURLWithPath: path))
            ok = true
        } catch {}
        openDB()
        reload()
        return ok
    }

    var ym: String { String(format: "%04d-%02d", year, month) }
    var prevYM: String { month == 1 ? String(format: "%04d-12", year - 1) : String(format: "%04d-%02d", year, month - 1) }

    private func bind(_ st: OpaquePointer?, _ i: Int32, _ v: Any) {
        if let s = v as? String { sqlite3_bind_text(st, i, s, -1, SQLITE_TRANSIENT) }
        else if let d = v as? Double { sqlite3_bind_double(st, i, d) }
        else if let n = v as? Int64 { sqlite3_bind_int64(st, i, n) }
    }

    @discardableResult
    func run(_ sql: String, _ args: [Any] = []) -> Bool {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() { bind(st, Int32(i + 1), a) }
        return sqlite3_step(st) == SQLITE_DONE
    }

    func rows(_ sql: String, _ args: [Any] = []) -> [[Any]] {
        var st: OpaquePointer?
        var out: [[Any]] = []
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() { bind(st, Int32(i + 1), a) }
        while sqlite3_step(st) == SQLITE_ROW {
            var r: [Any] = []
            for c in 0..<sqlite3_column_count(st) {
                switch sqlite3_column_type(st, c) {
                case SQLITE_INTEGER: r.append(sqlite3_column_int64(st, c))
                case SQLITE_FLOAT: r.append(sqlite3_column_double(st, c))
                case SQLITE_TEXT: r.append(String(cString: sqlite3_column_text(st, c)))
                default: r.append("")
                }
            }
            out.append(r)
        }
        return out
    }

    func reload() {
        func load(_ t: String, _ col: String) -> [Rec] {
            rows("SELECT id,d,\(col),amount,note FROM \(t) WHERE del=0 AND substr(d,1,7)=? ORDER BY d DESC,id DESC", [ym]).map {
                Rec(id: $0[0] as? Int64 ?? 0, d: $0[1] as? String ?? "", c: $0[2] as? String ?? "", a: toD($0[3]), n: $0[4] as? String ?? "")
            }
        }
        inc = load("income", "src")
        exp = load("expenses", "cat")
        var b: [String: Double] = [:]
        for r in rows("SELECT cat,lim FROM budgets WHERE del=0") { b[r[0] as? String ?? ""] = toD(r[1]) }
        bud = b
    }

    func catSums(_ month: String) -> [(key: String, value: Double)] {
        var o: [String: Double] = [:]
        for r in rows("SELECT cat,SUM(amount) FROM expenses WHERE del=0 AND substr(d,1,7)=? GROUP BY cat", [month]) { o[r[0] as? String ?? ""] = toD(r[1]) }
        return o.sorted { $0.value > $1.value }
    }

    func insight() -> String {
        let cur = Dictionary(uniqueKeysWithValues: catSums(ym).map { ($0.key, $0.value) })
        let prv = Dictionary(uniqueKeysWithValues: catSums(prevYM).map { ($0.key, $0.value) })
        if prv.isEmpty { return "لا توجد مصروفات في الشهر السابق للمقارنة." }
        var best = ("", 0.0)
        for k in Set(cur.keys).union(prv.keys) {
            let d = (cur[k] ?? 0) - (prv[k] ?? 0)
            if d > best.1 { best = (k, d) }
        }
        return best.1 > 0 ? "أكثر فئة ارتفاعاً عن الشهر السابق: \(best.0) (+\(fmt(best.1)))" : "لم يرتفع الإنفاق في أي فئة عن الشهر السابق."
    }

    func save(isInc: Bool, id: Int64?, d: String, c: String, a: Double, n: String) {
        let t = isInc ? "income" : "expenses"
        let col = isInc ? "src" : "cat"
        if let id = id {
            run("UPDATE \(t) SET d=?,\(col)=?,amount=?,note=? WHERE id=?", [d, c, a, n, id])
        } else {
            run("INSERT INTO \(t)(d,\(col),amount,note) VALUES(?,?,?,?)", [d, c, a, n])
        }
        year = Int(d.prefix(4)) ?? year
        month = Int(d.dropFirst(5).prefix(2)) ?? month
        reload()
    }

    func remove(isInc: Bool, id: Int64) {
        run("UPDATE \(isInc ? "income" : "expenses") SET del=1 WHERE id=?", [id])
        reload()
    }

    func setBudget(_ c: String, _ v: Double) {
        if v > 0 { run("INSERT INTO budgets(cat,lim,del) VALUES(?,?,0) ON CONFLICT(cat) DO UPDATE SET lim=excluded.lim, del=0", [c, v]) } else { run("UPDATE budgets SET del=1 WHERE cat=?", [c]) }
    }
}

@main
struct HisabatiApp: App {
    @StateObject private var store = Store()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "ar"))
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var s: Store
    @State private var form: FormInfo?
    @State private var showBudgets = false
    @State private var share: ShareItem?
    @State private var showImporter = false
    @State private var importMode = 0
    @State private var msg: String?

    var rows: [Row] {
        let all = s.inc.map { Row(id: "i\($0.id)", isInc: true, rec: $0) } + s.exp.map { Row(id: "e\($0.id)", isInc: false, rec: $0) }
        return all.sorted { $0.rec.d > $1.rec.d }
    }

    func card(_ title: String, _ value: Double, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundColor(.gray)
            Text(fmt(value)).font(.title3.bold()).foregroundColor(color)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(Color.white).cornerRadius(12)
    }

    var chartView: some View {
        let cur = s.catSums(s.ym)
        let mx = max(cur.first?.value ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(cur, id: \.key) { e in
                VStack(spacing: 2) {
                    Text(fmt(e.value)).font(.system(size: 9))
                    RoundedRectangle(cornerRadius: 4)
                        .fill((s.bud[e.key] ?? .infinity) < e.value ? Color.red : indigo)
                        .frame(height: max(4, 110 * e.value / mx))
                    Text(String(e.key.split(separator: " ").first ?? "")).font(.system(size: 10))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 150, alignment: .bottom)
    }

    func syncNow() {
        var stale = false
        if let b = UserDefaults.standard.data(forKey: "syncBookmark"),
           let url = try? URL(resolvingBookmarkData: b, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
            msg = s.syncWith(url)
        } else {
            importMode = 1
            showImporter = true
        }
    }

    var body: some View {
        let ti = s.inc.reduce(0) { $0 + $1.a }
        let te = s.exp.reduce(0) { $0 + $1.a }
        return NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    HStack {
                        Picker("الشهر", selection: $s.month) {
                            ForEach(1...12, id: \.self) { Text(MONTHS[$0 - 1]).tag($0) }
                        }
                        Picker("السنة", selection: $s.year) {
                            ForEach((s.year - 5)...(s.year + 2), id: \.self) { Text(String($0)).tag($0) }
                        }
                        Spacer()
                    }
                    .onChange(of: s.month) { _ in s.reload() }
                    .onChange(of: s.year) { _ in s.reload() }
                    HStack(spacing: 8) {
                        card("الدخل", ti, .green)
                        card("المصروفات", te, .red)
                        card("المتبقي", ti - te, navy)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("توزيع المصروفات حسب الفئة (الأحمر = تجاوز الميزانية)").font(.footnote.bold())
                        if s.exp.isEmpty { Text("لا توجد مصروفات في هذا الشهر").foregroundColor(.gray) } else { chartView }
                        Text(s.insight()).font(.footnote).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.yellow.opacity(0.2)).cornerRadius(8)
                    }
                    .padding().background(Color.white).cornerRadius(12)
                    ForEach(rows) { r in
                        Button { form = FormInfo(isInc: r.isInc, rec: r.rec) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(r.rec.c).foregroundColor(.primary)
                                    Text("\(r.rec.d)  \(r.rec.n)").font(.caption).foregroundColor(.gray)
                                }
                                Spacer()
                                Text(fmt(r.rec.a)).bold().foregroundColor(.primary)
                            }
                            .padding()
                            .background((r.isInc ? Color.green : Color.red).opacity(0.15)).cornerRadius(10)
                        }
                    }
                }
                .padding()
            }
            .background(Color(red: 0.95, green: 0.95, blue: 0.98))
            .navigationTitle("حساباتي")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("الميزانيات") { showBudgets = true } }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { syncNow() } label: { Label("تحديث", systemImage: "arrow.triangle.2.circlepath") }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button("نسخة احتياطية (مشاركة الملف)") { share = ShareItem(url: s.backupFile()) }
                        Button("استعادة نسخة احتياطية") { importMode = 0; showImporter = true }
                        Button("تغيير ملف المزامنة (Google Drive)") { importMode = 1; showImporter = true }
                    } label: { Image(systemName: "externaldrive") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Button { form = FormInfo(isInc: true, rec: nil) } label: { Text("+ دخل / راتب").bold().frame(maxWidth: .infinity).padding().background(Color.green).foregroundColor(.white).cornerRadius(12) }
                    Button { form = FormInfo(isInc: false, rec: nil) } label: { Text("+ مصروف").bold().frame(maxWidth: .infinity).padding().background(Color.red).foregroundColor(.white).cornerRadius(12) }
                }
                .padding().background(.ultraThinMaterial)
            }
            .sheet(item: $form) { f in FormView(info: f) }
            .sheet(isPresented: $showBudgets) { BudgetView() }
            .sheet(item: $share) { it in ShareSheet(url: it.url) }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { res in
                guard case .success(let u) = res else { return }
                if importMode == 1 {
                    if u.startAccessingSecurityScopedResource() {
                        if let b = try? u.bookmarkData() { UserDefaults.standard.set(b, forKey: "syncBookmark") }
                        u.stopAccessingSecurityScopedResource()
                    }
                    msg = s.syncWith(u)
                } else {
                    msg = s.restore(from: u) ? "تمت استعادة البيانات." : "تعذّرت الاستعادة."
                }
            }
            .alert(msg ?? "", isPresented: Binding(get: { msg != nil }, set: { if !$0 { msg = nil } })) { Button("حسناً", role: .cancel) {} }
        }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct FormView: View {
    @EnvironmentObject var s: Store
    @Environment(\.dismiss) var dismiss
    let info: FormInfo
    @State private var date = Date()
    @State private var cat = ""
    @State private var amount = ""
    @State private var note = ""
    @State private var bad = false

    var cats: [String] {
        var l = info.isInc ? SRC : CATS
        if !cat.isEmpty && !l.contains(cat) { l.append(cat) }
        return l
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("التاريخ", selection: $date, displayedComponents: .date)
                Picker(info.isInc ? "المصدر" : "الفئة", selection: $cat) { ForEach(cats, id: \.self) { Text($0).tag($0) } }
                TextField("المبلغ", text: $amount).keyboardType(.decimalPad)
                if bad { Text("أدخل مبلغاً صحيحاً").foregroundColor(.red) }
                TextField("ملاحظات", text: $note)
                if let r = info.rec {
                    Button("حذف السجل", role: .destructive) { s.remove(isInc: info.isInc, id: r.id); dismiss() }
                }
            }
            .navigationTitle(info.isInc ? "دخل / راتب" : "مصروف")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") {
                        guard let a = parseNum(amount) else { bad = true; return }
                        s.save(isInc: info.isInc, id: info.rec?.id, d: iso.string(from: date), c: cat, a: a, n: note)
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let r = info.rec {
                    date = iso.date(from: r.d) ?? Date()
                    cat = r.c
                    amount = r.a == r.a.rounded() ? String(Int(r.a)) : String(r.a)
                    note = r.n
                } else {
                    cat = (info.isInc ? SRC : CATS)[0]
                }
            }
        }
    }
}

struct BudgetView: View {
    @EnvironmentObject var s: Store
    @Environment(\.dismiss) var dismiss
    @State private var vals: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                ForEach(CATS, id: \.self) { c in
                    HStack {
                        Text(c)
                        TextField("بدون حد", text: Binding(get: { vals[c] ?? "" }, set: { vals[c] = $0 })).keyboardType(.decimalPad)
                    }
                }
            }
            .navigationTitle("الميزانية الشهرية لكل فئة")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") {
                        for c in CATS { s.setBudget(c, parseNum(vals[c] ?? "") ?? 0) }
                        s.reload()
                        dismiss()
                    }
                }
            }
            .onAppear { for (k, v) in s.bud { vals[k] = String(Int(v)) } }
        }
    }
}
