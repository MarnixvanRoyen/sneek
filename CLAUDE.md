# Sneek op z'n Haags — afspraken voor Claude

Snake-spel in Haags thema, live op **https://www.haagsesneek.nl** (GitHub Pages vanaf `main`, root). Openbare repo; het hele spel staat in `index.html`.
Achtergrond en werkwijze: repo `MarnixvanRoyen/haagse-content` → `claude/OVERZICHT.md` (deel 1) en `claude/ACTIES.md`.

## Zo gaat een wijziging live (sinds 18-11-2026, chat 73)
1. Claude werkt op een **eigen branch** (nooit direct op `main`; `main` zit op slot: alleen via pull request).
2. Eerst **testen + screenshot** (desktop én telefoonformaat) en laten zien aan Marnix.
3. Vóór het ok zegt Claude: **"dit gaat live"**.
4. Pas na **ok van Marnix**: commit → push → pull request → merge. GitHub Pages zet `main` binnen ± 1 minuut live.
5. Na ± 1 minuut checken op www.haagsesneek.nl (versieregeltje onderin het startscherm).
Nooit committen, pushen of mergen zonder ok, en nooit in een geplande taak.

## Vaste regels
- **Versieregeltje ophogen bij elke wijziging:** onderin het startscherm (`<span class="versie">` in `#makerStart`), vorm `versie JJJJ-MM-DD` + letter (a, b, c … bij meer versies op één dag).
- **Nie aan Supabase of SQL.** De beveiliging (`start_potje`, `bewaar_score_potje`, tabellen) blijft ongemoeid; Sneek-SQL staat in de privé repo `marreman-rojas-website`.
- **Geen geheimen** in deze repo (openbaar!). Alleen de publishable key bovenin `index.html` mag, die is openbaar bedoeld.
- **Sneek houdt z'n eigen look:** Titan One + Nunito (zelf gehost in `fonts/`), zand `#ecd9a8`, rood `#d9432f`, zeeblauw `#16323b`. Nie de huisstijl van het dashboard (Italiana/Forum) gebruiken.
- Teksten in het spel in plat Haags (regels: OVERZICHT.md deel 3); Pier, Kurhaus, Boulevard e.d. nie aanpassen.
- Kleine wijzigingen: alleen de regels die veranderen, nooit het hele bestand overtypen.
- Nieuw deelplaatje? `og.png?v=N` ophogen.
- Chats die `index.html` raken **na elkaar**, nooit twee tegelijk (zie ACTIES.md → Volgorde).

## Mac
`~/Developer/sneek` is alleen nog een kopie: Marnix pullt maandelijks. De oude Terminal-push werkt nie meer (slot op `main`).
