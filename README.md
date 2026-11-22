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

## Build

Build-ul se face automat în **GitHub Actions** la fiecare push pe `main`. APK-ul apare în release-ul `latest`, iar capturile de ecran în release-ul `screens`.

Pe PC: rulează **`Ncommander.bat`** (de oriunde, chiar și de pe Desktop):

- `[1]` descarcă ultimul APK în `D:\Apps\Ncommander\dist`
- `[2]` îl instalează pe telefon prin cablu USB (descarcă singur `adb` prima dată)
- `[4]` / `[5]` actualizează codul / build local, doar dacă ai Flutter

Toate build-urile sunt semnate cu aceeași cheie (`tool/debug.keystore`), așa că un APK nou se instalează peste cel vechi.

La prima pornire aplicația cere **acces la toate fișierele** (necesar pentru un manager de fișiere pe Android 11+).
