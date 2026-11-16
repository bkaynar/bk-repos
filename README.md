# BK Repos

Tüm git depolarınızda **kaybolabilecek işi** gösteren bir macOS menü çubuğu uygulaması: commit'lenmemiş değişiklikler, push'lanmamış commit'ler, uzak deposu olmayan projeler, unutulmuş dallar, stash'ler ve çalışma ağaçları (worktree).

Tarama yalnızca salt okunur git komutları çalıştırır ve **ağa çıkmaz**. Depoyu değiştiren dört işlem vardır; hepsi düğmeyle başlar ve (Getir dışında) onay ister.

## Nasıl çalışır

1. Menü çubuğunda yaşar. Kritik depo varsa simgenin yanında sayısı yazar.
2. Açılışta ve 30 dakikada bir arka planda tarar (dakikada bir ve uyku sonrası, zamanı geldi mi diye bakar).
3. Pencerede solda aranabilir depo listesi (risk etiketleriyle), sağda **Genel Bakış** ya da seçilen deponun ayrıntıları vardır.
4. Her gün saat 18:00'den sonra bir kez taze tarama yapar; Kritik depo varsa "2 projede kaybolabilecek iş var" bildirimi gönderir. Bildirime tıklamak pencereyi açar. Bildirim izni yoksa pencere doğrudan açılır.

Menü: özet satırı, **Pencereyi aç**, **Şimdi tara**, **Girişte otomatik başlat**, **Ayarlar dosyasını aç…**, **Çık**.

## Depolar nasıl bulunur

- `roots` altındaki klasörler 3 seviye derine kadar gezilir (`kök/ad` = 1. seviye). İç içe depolar ayrı depo olarak listelenir.
- Noktayla başlayan klasörlere (`.build`, `.dart_tool`, `.git`…) ve `node_modules`, `build`, `Pods`, `DerivedData`, `dist`, `target`, `vendor`, `venv`, `Carthage`, `out` klasörlerine girilmez. Sembolik bağlantılar izlenmez.
- Bağlı çalışma ağaçları (`git worktree list --porcelain`) ayrı depo sayılmaz; ait oldukları deponun altında gösterilir. Örneğin `trafik360/.claude/worktrees/…` altındaki ajan çalışma ağaçları `trafik360` deposunun ayrıntısında görünür.
- **Kopuk çalışma ağaçları:** `.git` dosyası olan ama gösterdiği git klasörü bulunmayan klasörler (ör. başka bilgisayardan kopyalanmış ajan klasörleri) git tarafından tanınmaz. Bunlar `.claude/worktrees`, `.worktrees`, `worktrees` altında ve keşif sırasında aranır, deponun altında "kopuk" olarak gösterilir.
- Alt modüller (submodule) ve çıplak (bare) depolar listelenmez.

## Her depo için toplananlar

| Bilgi | Komut |
|---|---|
| Dal / ayrık HEAD, upstream, ileride/geride, hazırlanmış / değişmiş / izlenmeyen sayıları | `git status --porcelain=v2 --branch -z --untracked-files=normal` |
| En eski commit'lenmemiş değişikliğin yaşı | değişen dosyaların değiştirilme tarihleri |
| Stash sayısı ve en eskisi | `git stash list --format=%ct` |
| Son commit | `git log -1` |
| Uzak depolar | `git remote -v` |
| Yerel dallar, upstream'leri, hangi çalışma ağacında açık oldukları | `git for-each-ref refs/heads` |
| Hiçbir uzak depoda olmayan commit'ler | `git log <dal> --not --remotes` |
| Varsayılan dal | `git symbolic-ref refs/remotes/origin/HEAD`, yoksa `main` / `master` / `develop` / `trunk` |
| Varsayılan dala birleştirilmiş dallar | `git for-each-ref --merged=<varsayılan>` (yerel ve uzak hâli) |
| Çalışma ağaçları: yol, dal, temiz/kirli, son etkinlik | `git worktree list --porcelain` + her birinde `git status` |
| Ayrık HEAD'de sahipsiz commit'ler | `git rev-list --count HEAD --not --branches --remotes` |

Git her zaman `/usr/bin/git` ile, `GIT_OPTIONAL_LOCKS=0` (status `index.lock` almaz), `LC_ALL=C` ve `GIT_TERMINAL_PROMPT=0` ortamıyla, zaman aşımıyla çalışır. Depolar aynı anda en fazla 4'er taranır. İleride/geride sayıları **yerel bilgiye** göredir; tarama sırasında fetch yapılmaz.

## Risk düzeyleri

| Düzey | Ne zaman |
|---|---|
| **Kritik** | Commit var ama hiç uzak depo yok · push'lanmamış commit 1 günden eski · commit'lenmemiş değişiklik 3 günden eski (çalışma ağaçlarında da) · uzak depoda hiç bulunmayan bir dalda benzersiz commit var · ayrık HEAD'de hiçbir dalda olmayan commit var |
| **Uyarı** | Yeni push'lanmamış / commit'lenmemiş iş · stash var · temiz ve 14 gündür dokunulmamış çalışma ağacı · kopuk ya da klasörü silinmiş çalışma ağacı · silinebilecek birleştirilmiş dallar · depo taranamadı |
| **Temiz** | Hiçbiri |

Liste riske göre sıralıdır. Bulgular düz Türkçe yazılır: "3 commit push'lanmamış (2 gündür)", "Uzak depo yok: bu projenin tek kopyası bu bilgisayarda".

## İşlemler

Her zaman: **Finder'da aç**, **Terminal'de aç**, **Editörde aç** (Antigravity IDE, VS Code, Cursor, Android Studio, Xcode; yalnızca kurulu olanlar sunulur).

Uygulamanın çalıştırabildiği, depoyu değiştiren git komutlarının **tamamı** şunlardır (`Sources/BKReposCore/Git.swift` içindeki `GitMutation`):

| Düğme | Komut | Ön koşul |
|---|---|---|
| Getir | `git fetch --all --prune` | Yalnızca düğmeye basınca; uzak depo tanımlı olmalı |
| Push'la | `git push` | Dal bir upstream'e bağlı, ileride > 0, geride = 0. Onayda commit'ler listelenir. Zorlama (force) yoktur |
| Çalışma ağacını kaldır | `git worktree remove <yol>` | `--force` yok. Kayıtlı, ana olmayan, kilitsiz, tamamen temiz ve sahipsiz commit'i olmayan çalışma ağacı. Kirliyse neden kaldırılamadığı gösterilir |
| Dalı sil | `git branch -d -- <dal>` | Hiçbir zaman `-D`. Varsayılan dala birleştirilmiş; geçerli dal, varsayılan dal ya da bir çalışma ağacında açık dal değil |

- Her işlem, komutu çalıştırmadan hemen önce depoyu yeniden tarar ve ön koşulu bir kez daha denetler.
- Git reddederse git'in kendi hata metni gösterilir.
- Tarama komutları ayrı bir kapıdan (`Git.read`) geçer; bu kapı yalnızca salt okunur alt komutları kabul eder. `reset`, `checkout`, `clean`, `stash drop`, `pull`, `rebase` hiçbir yerde yoktur.
- Çalışma ağacı kaldırılırken git'in yok saydığı dosyalar (`.env`, derleme çıktıları) da silinir; onay penceresi bunları listeler.

## Kurulum

```bash
./build.sh               # build/BK Repos.app oluşturur
./build.sh --install     # ayrıca ~/Applications'a kurar, masaüstüne kısayol koyar ve açar
```

İlk açılışta macOS bildirim izni ve (depolarınız Belgeler altındaysa) Belgeler klasörü erişimi sorabilir. Menüden **Girişte otomatik başlat** seçeneğini açın.

## Denemek

```bash
swift run bkrepos-durum          # bulguları risk düzeyine göre terminalde listeler; hiçbir şeyi değiştirmez
swift run bkrepos-durum --kisa   # yalnızca depo adları ve risk düzeyleri
swift test                       # ayrıştırıcılar, risk sınıflandırması ve işlem ön koşulları
```

Testler kullanıcının depolarına dokunmaz: geçici klasörde kendi depolarını, çıplak bir "uzak depo"yu, dalları, stash'leri ve çalışma ağaçlarını kurar. Çok sayıda git süreci başlattıkları için bir-iki dakika sürer.

Pencereyi ekranda açmadan görmek için (bildirim izni istemez, hiçbir şey kaydetmez):

```bash
swift build && .build/debug/BKRepos --anlik-goruntu /tmp/bkrepos.png [--depo <ad>]
```

## Ayarlar

`~/Library/Application Support/BKRepos/config.json` (menü → **Ayarlar dosyasını aç…** ilk seferde varsayılanlarla oluşturur). Dosyada olmayan alanlar varsayılanı alır.

| Alan | Varsayılan | Anlamı |
|---|---|---|
| `roots` | `["~/Documents/GitHub", "~/IdeaProjects"]` | Depoların arandığı klasörler |
| `maxDepth` | `3` | Kök altında inilecek derinlik |
| `skipDirectories` | `node_modules`, `build`, `Pods`… | İçine girilmeyen klasör adları |
| `worktreeDirectories` | `.claude/worktrees`, `.worktrees`, `worktrees` | Kopuk çalışma ağaçlarının arandığı, depoya göreli klasörler |
| `unpushedCriticalDays` | `1` | Push'lanmamış commit bu kadar günden eskiyse Kritik |
| `uncommittedCriticalDays` | `3` | Commit'lenmemiş değişiklik bu kadar günden eskiyse Kritik |
| `staleWorktreeDays` | `14` | Temiz çalışma ağacı bu kadar gündür dokunulmadıysa uyarı |
| `reminderEnabled`, `reminderTime` | `true`, `"18:00"` | Günlük hatırlatma |
| `scanIntervalMinutes` | `30` | Arka plan taramaları arasındaki süre |
| `parallelism` | `4` | Aynı anda taranan depo sayısı |
| `ignoredRepos` | `[]` | Listelenmeyecek depo yolları |

## Bilinen sınırlar

- Uzak depoların durumu en son `fetch` anındaki bilgidir; güncellemek için **Getir** düğmesi.
- Squash ya da rebase ile birleştirilmiş dallar "birleştirilmiş" olarak algılanmaz.
- "En eski değişiklik" dosyanın değiştirilme tarihine bakar; yalnızca silinmiş dosyalar varsa yaş bilinmez ve Uyarı düzeyinde kalır. Eski tarihli olarak kopyalanmış izlenmeyen bir dosya yaşı olduğundan büyük gösterebilir.
- Kopuk çalışma ağaçlarının içeriği git ile incelenemez; yalnızca varlıkları bildirilir.
