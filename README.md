# Ncommander

Manager de fișiere cu **două panouri** pentru **Android**, în stilul Total Commander, cu finisaj Material 3. **Fără reclame, fără cont.** Română + English, temă luminoasă / întunecată. by norAz

## Funcții

- **Două panouri**: una sub alta pe telefon în portret, alăturate în landscape sau pe ecran mare (Fold deschis). Separatorul se trage pentru a schimba proporția; dublu-tap îl readuce la mijloc.
- **Tab-uri** în fiecare panou, păstrate la redeschidere.
- **Copiere / Mutare spre celălalt panou** (ca F5/F6), cu ținta editabilă, progres, oprire și întrebare la conflicte: înlocuiește / omite / redenumește, cu „pentru toate”.
- Mutarea pe același volum e instantanee; între volume (ex. card SD) se copiază și se șterge doar ce a reușit.
- **Selecție rapidă**: tap pe iconiță, apăsare lungă, apăsare lungă pe alt rând = interval, după mască (`*.jpg;*.png`), totul, inversare.
- Redenumire, folder / fișier nou, ștergere cu confirmare.
- **ZIP**: arhivare, răsfoire în arhivă, deschidere fișier din arhivă, dezarhivare aici / în folder / în celălalt panou.
- **Căutare** recursivă după nume sau mască, rezultate pe măsură ce apar.
- **Filtru rapid** în panou, sortare după nume (naturală), extensie, mărime, dată.
- Vizualizator imagini cu swipe și zoom; editor text integrat (vizualizare / editare, încadrare, mărime font).
- Miniaturi pentru poze, video, coperți audio, PDF și iconițe APK.
- Volume (memorie internă, card SD, USB) cu spațiu liber, foldere uzuale, favorite.
- Proprietăți: mărime recursivă, conținut, dată, permisiuni.
- Panourile se reîmprospătează singure când se schimbă fișierele.
- Vizualizare **tabel** (Nume / Mărime / Dată, antet sortabil) sau listă pe două rânduri.
- **Căutare avansată**: mască, tip, mărime, dată, text în conținut.

## Rețea și cloud

Meniu ☰ › **Adaugă conexiune**. Conexiunea se deschide ca un volum în oricare panou; copierea / mutarea merg în orice direcție (telefon ↔ FTP ↔ Drive ↔ OneDrive).

- **FTP / FTPS**: server, port, utilizator (gol = anonim), parolă, folder de pornire, TLS explicit (sau implicit pe portul 990). Butonul *Testează* verifică setările.
- **Google Drive** — configurare unică în [Google Cloud Console](https://console.cloud.google.com/):
  1. Proiect nou → *APIs & Services* → activează **Google Drive API**.
  2. *OAuth consent screen*: External, adaugă-ți adresa Gmail la *Test users*.
  3. *Credentials* → *Create credentials* → *OAuth client ID* → tip **Android**: package `ro.noraz.ncommander`, SHA-1 `B9:4A:AA:16:8C:68:8F:72:3B:9F:49:A4:3B:08:63:8B:81:01:1D:B6`.
  4. În aplicație: Adaugă conexiune → Google Drive → alegi contul.
- **OneDrive** — configurare unică în [Azure Portal → App registrations](https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade):
  1. *New registration*, conturi: **Accounts in any organizational directory and personal Microsoft accounts**.
  2. *Authentication* → *Add a platform* → **Mobile and desktop applications** → redirect URI personalizat `ncommander://auth`; *Allow public client flows* = Yes.
  3. Copiezi **Application (client) ID** și îl lipești în aplicație la prima conexiune OneDrive.

Ștergerea pe Drive / OneDrive trimite fișierele în coșul din cloud.

## Build

Build-ul se face automat în **GitHub Actions** la fiecare push pe `main`. APK-ul apare în release-ul `latest`, iar capturile de ecran în release-ul `screens`.

Pe PC: rulează **`Ncommander.bat`** (de oriunde, chiar și de pe Desktop):

- `[1]` descarcă ultimul APK în `D:\Apps\Ncommander\dist`
- `[2]` îl instalează pe telefon prin cablu USB (descarcă singur `adb` prima dată)
- `[4]` / `[5]` actualizează codul / build local, doar dacă ai Flutter

Toate build-urile sunt semnate cu aceeași cheie (`tool/debug.keystore`), așa că un APK nou se instalează peste cel vechi.

La prima pornire aplicația cere **acces la toate fișierele** (necesar pentru un manager de fișiere pe Android 11+).

## Windows

Bara de discuri de deasupra fiecărui panou are în dreapta butonul **FTP**: lista serverelor salvate se deschide în panoul respectiv (Enter / dublu-clic conectează, click dreapta: redenumire, editare, eliminare; ultimul rând adaugă un server). Meniul lateral păstrează doar folderele obișnuite și favoritele.

`Ncommander-windows.zip` din release-ul „latest” (sau opțiunea **[6]** din `Ncommander.bat`, care îl instalează în `D:\Apps\Ncommander\win` și pune o scurtătură pe Desktop).
Discuri locale și de rețea, FTP, aceleași teme. Google Drive și OneDrive apar deja ca foldere pe Windows, așa că lipsesc din „Conexiune nouă”.
Taste Total Commander (merg și cu tastatură pe telefon); comenzile lucrează pe selecție sau, fără selecție, pe rândul cu cursorul:
- săgeți, PgUp/PgDn, Home/End mută cursorul; Shift+săgeți selectează; Insert selectează și coboară; Space selectează
- Enter deschide cu aplicația implicită, F3 / Ctrl+Q previzualizare (PDF, docx, xlsx, pptx), F4 editează, Backspace / Ctrl+PgUp folderul părinte, Ctrl+PgDn intră în folder
- F5 copiere, F6 mutare, Shift+F6 / F2 redenumire, F7 nou, F8 / Delete ștergere
- Alt+F7 căutare, Alt+F5 arhivează, Alt+F9 dezarhivează, Alt+Enter proprietăți
- Tab panoul celălalt, Alt+F1 / Alt+F2 locații stânga / dreapta, Ctrl+D locații, Ctrl+U inversează panourile
- Ctrl+←/→ deschide folderul de sub cursor în panoul stâng / drept
- Num+ selectează după mască, Num− deselectează, Num* inversează, Ctrl+A tot, Esc anulează selecția
- Ctrl+F conectare FTP (lista serverelor), Ctrl+Shift+F deconectare, Ctrl+N server nou
- Enter / Ctrl+PgDn pe un .zip intră în arhivă ca într-un folder (F5 copiază afară, Backspace iese)
- Ctrl+F1 compact, Ctrl+F2 detaliat, Ctrl+Shift+F1 miniaturi
- Ctrl+S filtru, Ctrl+H fișiere ascunse, Ctrl+T / Ctrl+W tab nou / închide, Ctrl+Tab tab următor, Ctrl+R reîmprospătare
- click dreapta = selectare
