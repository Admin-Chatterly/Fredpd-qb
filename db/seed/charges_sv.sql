-- SPDX-License-Identifier: GPL-3.0-only
-- Brottskatalog (fredpd_charges, 003_records.sql): Swedish charges for the game. Sweden has no licence points;
-- traffic consequences beyond the fine (varning / återkallelse) are handled in reports, not here.
--
-- fine is in SEK and game-balanced (not the real amounts); jail_min is game jail time in minutes; class is
-- 'ordningsbot' (on-the-spot fine), 'bot' (böter via strafföreläggande / domstol) or 'fängelse'.
-- law_ref: BrB = brottsbalken, TBL = lag (1951:649) om straff för vissa trafikbrott, TrF = trafikförordningen
-- (1998:1276), VMF = vägmärkesförordningen (2007:90), NSL = narkotikastrafflagen (1968:64), OL = ordningslagen
-- (1993:1617). References are for flavour and must be reviewed by Rami with the values (task 5.4).
-- category keys (labels come from the locale): penal, traffic, narcotics, weapons, public_order, other.
--
-- Codes are permanent: never renumber or reuse one (fredpd_records references them). Retire a charge by setting
-- active = 0 in the admin UI; this seed never touches `active`.
-- Idempotent: applied by the migration runners when new or changed (tracked as seed/charges_sv.sql in
-- fredpd_migrations); existing codes are updated in place, and their updated_at moves only when a value changed.

INSERT INTO fredpd_charges (code, category, title_sv, law_ref, class, fine, jail_min) VALUES
  -- Brottsbalken: liv och hälsa, frihet och frid
  ('BRB-001', 'penal', 'Mord', 'BrB 3 kap. 1 §', 'fängelse', 0, 60),
  ('BRB-002', 'penal', 'Försök till mord', 'BrB 3 kap. 1 och 11 §§', 'fängelse', 0, 40),
  ('BRB-003', 'penal', 'Dråp', 'BrB 3 kap. 2 §', 'fängelse', 0, 45),
  ('BRB-004', 'penal', 'Ringa misshandel', 'BrB 3 kap. 5 § 2 st.', 'bot', 4000, 0),
  ('BRB-005', 'penal', 'Misshandel', 'BrB 3 kap. 5 §', 'fängelse', 5000, 10),
  ('BRB-006', 'penal', 'Grov misshandel', 'BrB 3 kap. 6 §', 'fängelse', 10000, 20),
  ('BRB-007', 'penal', 'Synnerligen grov misshandel', 'BrB 3 kap. 6 § 2 st.', 'fängelse', 15000, 30),
  ('BRB-008', 'penal', 'Vållande till annans död', 'BrB 3 kap. 7 §', 'fängelse', 10000, 15),
  ('BRB-009', 'penal', 'Grovt vållande till annans död', 'BrB 3 kap. 7 § 2 st.', 'fängelse', 20000, 25),
  ('BRB-010', 'penal', 'Framkallande av fara för annan', 'BrB 3 kap. 9 §', 'bot', 8000, 0),
  ('BRB-011', 'penal', 'Människorov', 'BrB 4 kap. 1 §', 'fängelse', 0, 40),
  ('BRB-012', 'penal', 'Olaga frihetsberövande', 'BrB 4 kap. 2 §', 'fängelse', 5000, 20),
  ('BRB-013', 'penal', 'Olaga tvång', 'BrB 4 kap. 4 §', 'fängelse', 5000, 10),
  ('BRB-014', 'penal', 'Olaga hot', 'BrB 4 kap. 5 §', 'fängelse', 3000, 5),
  ('BRB-015', 'penal', 'Grovt olaga hot', 'BrB 4 kap. 5 § 2 st.', 'fängelse', 5000, 15),
  ('BRB-016', 'penal', 'Hemfridsbrott', 'BrB 4 kap. 6 §', 'bot', 5000, 0),
  ('BRB-017', 'penal', 'Olaga intrång', 'BrB 4 kap. 6 § 2 st.', 'bot', 3000, 0),
  ('BRB-018', 'penal', 'Ofredande', 'BrB 4 kap. 7 §', 'bot', 3000, 0),
  -- Brottsbalken: förmögenhetsbrott
  ('BRB-019', 'penal', 'Snatteri', 'BrB 8 kap. 2 §', 'bot', 2000, 0),
  ('BRB-020', 'penal', 'Stöld', 'BrB 8 kap. 1 §', 'fängelse', 3000, 5),
  ('BRB-021', 'penal', 'Grov stöld', 'BrB 8 kap. 4 §', 'fängelse', 8000, 15),
  ('BRB-022', 'penal', 'Rån', 'BrB 8 kap. 5 §', 'fängelse', 10000, 25),
  ('BRB-023', 'penal', 'Grovt rån', 'BrB 8 kap. 6 §', 'fängelse', 20000, 40),
  ('BRB-024', 'penal', 'Försök till rån', 'BrB 8 kap. 5 och 12 §§', 'fängelse', 5000, 15),
  ('BRB-025', 'penal', 'Tillgrepp av fortskaffningsmedel', 'BrB 8 kap. 7 §', 'fängelse', 5000, 10),
  ('BRB-026', 'penal', 'Bedrägeri', 'BrB 9 kap. 1 §', 'fängelse', 5000, 10),
  ('BRB-027', 'penal', 'Grovt bedrägeri', 'BrB 9 kap. 3 §', 'fängelse', 15000, 25),
  ('BRB-028', 'penal', 'Utpressning', 'BrB 9 kap. 4 §', 'fängelse', 10000, 20),
  ('BRB-029', 'penal', 'Häleri', 'BrB 9 kap. 6 §', 'fängelse', 5000, 10),
  ('BRB-030', 'penal', 'Givande av muta', 'BrB 10 kap. 5 b §', 'fängelse', 10000, 10),
  ('BRB-031', 'penal', 'Olovligt brukande', 'BrB 10 kap. 7 §', 'bot', 4000, 0),
  -- Brottsbalken: skadegörelse och allmänfarliga brott
  ('BRB-032', 'penal', 'Ringa skadegörelse', 'BrB 12 kap. 2 §', 'bot', 2000, 0),
  ('BRB-033', 'penal', 'Skadegörelse', 'BrB 12 kap. 1 §', 'bot', 5000, 0),
  ('BRB-034', 'penal', 'Grov skadegörelse', 'BrB 12 kap. 3 §', 'fängelse', 10000, 15),
  ('BRB-035', 'penal', 'Klotter', 'BrB 12 kap. 1 §', 'bot', 3000, 0),
  ('BRB-036', 'penal', 'Mordbrand', 'BrB 13 kap. 1 §', 'fängelse', 10000, 30),
  ('BRB-037', 'penal', 'Grov mordbrand', 'BrB 13 kap. 2 §', 'fängelse', 20000, 45),
  ('BRB-038', 'penal', 'Allmänfarlig ödeläggelse', 'BrB 13 kap. 3 §', 'fängelse', 20000, 40),
  -- Brottsbalken: förfalskning, allmän ordning, rättskipning
  ('BRB-039', 'penal', 'Urkundsförfalskning', 'BrB 14 kap. 1 §', 'fängelse', 5000, 10),
  ('BRB-040', 'penal', 'Penningförfalskning', 'BrB 14 kap. 6 §', 'fängelse', 10000, 20),
  ('BRB-041', 'penal', 'Brukande av falsk handling', 'BrB 14 kap. 10 §', 'bot', 5000, 0),
  ('BRB-042', 'penal', 'Våldsamt upplopp', 'BrB 16 kap. 2 §', 'fängelse', 5000, 15),
  ('BRB-043', 'penal', 'Ohörsamhet mot ordningsmakten', 'BrB 16 kap. 3 §', 'bot', 2500, 0),
  ('BRB-044', 'penal', 'Djurplågeri', 'BrB 16 kap. 13 §', 'bot', 5000, 0),
  ('BRB-045', 'penal', 'Falskt larm', 'BrB 16 kap. 15 §', 'bot', 4000, 0),
  ('BRB-046', 'penal', 'Förargelseväckande beteende', 'BrB 16 kap. 16 §', 'ordningsbot', 1500, 0),
  ('BRB-047', 'penal', 'Våld mot tjänsteman', 'BrB 17 kap. 1 §', 'fängelse', 5000, 15),
  ('BRB-048', 'penal', 'Hot mot tjänsteman', 'BrB 17 kap. 1 §', 'fängelse', 3000, 10),
  ('BRB-049', 'penal', 'Förgripelse mot tjänsteman', 'BrB 17 kap. 2 §', 'bot', 4000, 0),
  ('BRB-050', 'penal', 'Våldsamt motstånd', 'BrB 17 kap. 4 §', 'bot', 5000, 0),
  ('BRB-051', 'penal', 'Övergrepp i rättssak', 'BrB 17 kap. 10 §', 'fängelse', 5000, 15),
  ('BRB-052', 'penal', 'Skyddande av brottsling', 'BrB 17 kap. 11 §', 'bot', 5000, 0),
  ('BRB-053', 'penal', 'Befrielse av fånge', 'BrB 17 kap. 12 §', 'fängelse', 10000, 20),
  ('BRB-054', 'penal', 'Föregivande av allmän ställning', 'BrB 17 kap. 15 §', 'bot', 5000, 0),
  ('BRB-055', 'penal', 'Tjänstefel', 'BrB 20 kap. 1 §', 'bot', 5000, 0),
  -- Trafikbrott (TBL)
  ('TRF-001', 'traffic', 'Vårdslöshet i trafik', 'TBL 1 §', 'bot', 4000, 0),
  ('TRF-002', 'traffic', 'Grov vårdslöshet i trafik', 'TBL 1 § 2 st.', 'fängelse', 8000, 10),
  ('TRF-003', 'traffic', 'Olovlig körning', 'TBL 3 §', 'bot', 4000, 0),
  ('TRF-004', 'traffic', 'Grov olovlig körning', 'TBL 3 § 2 st.', 'fängelse', 5000, 10),
  ('TRF-005', 'traffic', 'Rattfylleri', 'TBL 4 §', 'bot', 6000, 0),
  ('TRF-006', 'traffic', 'Drograttfylleri', 'TBL 4 § 2 st.', 'bot', 6000, 0),
  ('TRF-007', 'traffic', 'Grovt rattfylleri', 'TBL 4 a §', 'fängelse', 10000, 15),
  ('TRF-008', 'traffic', 'Smitning från trafikolycksplats', 'TBL 5 §', 'bot', 5000, 0),
  -- Hastighetsöverträdelse (km/h över tillåten hastighet)
  ('TRF-009', 'traffic', 'Hastighetsöverträdelse 1–10 km/h', 'TrF 3 kap. 17 §', 'ordningsbot', 1500, 0),
  ('TRF-010', 'traffic', 'Hastighetsöverträdelse 11–15 km/h', 'TrF 3 kap. 17 §', 'ordningsbot', 2000, 0),
  ('TRF-011', 'traffic', 'Hastighetsöverträdelse 16–20 km/h', 'TrF 3 kap. 17 §', 'ordningsbot', 2500, 0),
  ('TRF-012', 'traffic', 'Hastighetsöverträdelse 21–25 km/h', 'TrF 3 kap. 17 §', 'ordningsbot', 3000, 0),
  ('TRF-013', 'traffic', 'Hastighetsöverträdelse 26–30 km/h', 'TrF 3 kap. 17 §', 'ordningsbot', 3500, 0),
  ('TRF-014', 'traffic', 'Hastighetsöverträdelse 31–40 km/h', 'TrF 3 kap. 17 §', 'bot', 5000, 0),
  ('TRF-015', 'traffic', 'Hastighetsöverträdelse 41–50 km/h', 'TrF 3 kap. 17 §', 'bot', 7000, 0),
  ('TRF-016', 'traffic', 'Hastighetsöverträdelse 51–60 km/h', 'TrF 3 kap. 17 §', 'bot', 9000, 0),
  ('TRF-017', 'traffic', 'Hastighetsöverträdelse över 60 km/h', 'TrF 3 kap. 17 §', 'bot', 12000, 0),
  -- Trafikregler och fordon
  ('TRF-018', 'traffic', 'Körning mot rött ljus', 'VMF 3 kap.', 'ordningsbot', 3000, 0),
  ('TRF-019', 'traffic', 'Stopplikt ej iakttagen', 'VMF 2 kap.', 'ordningsbot', 2500, 0),
  ('TRF-020', 'traffic', 'Ej lämnat företräde', 'TrF 3 kap.', 'ordningsbot', 2000, 0),
  ('TRF-021', 'traffic', 'Otillåten omkörning', 'TrF 3 kap.', 'ordningsbot', 2500, 0),
  ('TRF-022', 'traffic', 'Ej använt bilbälte', 'TrF 4 kap. 10 §', 'ordningsbot', 1500, 0),
  ('TRF-023', 'traffic', 'Handhållen mobiltelefon under körning', 'TrF 4 kap. 10 e §', 'ordningsbot', 1500, 0),
  ('TRF-024', 'traffic', 'Motorcykel eller moped utan hjälm', 'TrF 4 kap.', 'ordningsbot', 1500, 0),
  ('TRF-025', 'traffic', 'Ej stannat på polismans tecken', 'TrF 2 kap.', 'bot', 4000, 0),
  ('TRF-026', 'traffic', 'Hindrande av utryckningsfordon', 'TrF 2 kap.', 'ordningsbot', 2000, 0),
  ('TRF-027', 'traffic', 'Felparkering', 'TrF 3 kap.', 'ordningsbot', 800, 0),
  ('TRF-028', 'traffic', 'Bristfällig utrustning på fordon', 'Fordonsförordningen (2009:211)', 'ordningsbot', 1500, 0),
  ('TRF-029', 'traffic', 'Brukande av fordon med falska registreringsskyltar', 'Lag (2019:370) om fordons registrering och användning', 'bot', 5000, 0),
  ('TRF-030', 'traffic', 'Ej medfört körkort', 'Körkortsförordningen (1998:980)', 'ordningsbot', 500, 0),
  ('TRF-031', 'traffic', 'Olovlig tävling med fordon', 'TrF 3 kap.', 'bot', 6000, 0),
  ('TRF-032', 'traffic', 'Obehörig användning av blåljus', 'Fordonsförordningen (2009:211)', 'bot', 5000, 0),
  -- Narkotika
  ('NAR-001', 'narcotics', 'Ringa narkotikabrott (eget bruk)', 'NSL 2 §', 'bot', 3000, 0),
  ('NAR-002', 'narcotics', 'Ringa narkotikabrott (innehav)', 'NSL 2 §', 'bot', 4000, 0),
  ('NAR-003', 'narcotics', 'Narkotikabrott', 'NSL 1 §', 'fängelse', 5000, 10),
  ('NAR-004', 'narcotics', 'Narkotikabrott (försäljning)', 'NSL 1 §', 'fängelse', 10000, 15),
  ('NAR-005', 'narcotics', 'Narkotikabrott (odling eller tillverkning)', 'NSL 1 §', 'fängelse', 10000, 20),
  ('NAR-006', 'narcotics', 'Grovt narkotikabrott', 'NSL 3 §', 'fängelse', 20000, 30),
  ('NAR-007', 'narcotics', 'Synnerligen grovt narkotikabrott', 'NSL 3 a §', 'fängelse', 30000, 50),
  ('NAR-008', 'narcotics', 'Narkotikasmuggling', 'Lag (2000:1225) om straff för smuggling 6 §', 'fängelse', 10000, 15),
  ('NAR-009', 'narcotics', 'Grov narkotikasmuggling', 'Lag (2000:1225) om straff för smuggling 6 §', 'fängelse', 20000, 30),
  ('NAR-010', 'narcotics', 'Dopningsbrott', 'Lag (1991:1969) om förbud mot vissa dopningsmedel 3 §', 'bot', 5000, 0),
  ('NAR-011', 'narcotics', 'Grovt dopningsbrott', 'Lag (1991:1969) om förbud mot vissa dopningsmedel 3 a §', 'fängelse', 10000, 15),
  -- Vapen och explosiva varor
  ('VAP-001', 'weapons', 'Ringa vapenbrott', 'Vapenlagen (1996:67) 9 kap. 1 §', 'bot', 5000, 0),
  ('VAP-002', 'weapons', 'Vapenbrott', 'Vapenlagen (1996:67) 9 kap. 1 §', 'fängelse', 5000, 15),
  ('VAP-003', 'weapons', 'Grovt vapenbrott', 'Vapenlagen (1996:67) 9 kap. 1 a §', 'fängelse', 10000, 30),
  ('VAP-004', 'weapons', 'Synnerligen grovt vapenbrott', 'Vapenlagen (1996:67) 9 kap. 1 a § 2 st.', 'fängelse', 20000, 45),
  ('VAP-005', 'weapons', 'Vapenvårdslöshet', 'Vapenlagen (1996:67) 9 kap. 3 §', 'bot', 4000, 0),
  ('VAP-006', 'weapons', 'Olovlig överlåtelse av vapen', 'Vapenlagen (1996:67) 9 kap. 2 §', 'fängelse', 10000, 15),
  ('VAP-007', 'weapons', 'Brott mot knivlagen', 'Lag (1988:254) om förbud beträffande knivar och andra farliga föremål 4 §', 'bot', 3000, 0),
  ('VAP-008', 'weapons', 'Olovligt innehav av explosiv vara', 'Lag (2010:1011) om brandfarliga och explosiva varor 29 §', 'fängelse', 10000, 20),
  ('VAP-009', 'weapons', 'Olovligt innehav av explosiv vara, grovt brott', 'Lag (2010:1011) om brandfarliga och explosiva varor 29 §', 'fängelse', 20000, 35),
  ('VAP-010', 'weapons', 'Vapensmuggling', 'Lag (2000:1225) om straff för smuggling', 'fängelse', 15000, 30),
  ('VAP-011', 'weapons', 'Skjutning inom detaljplanelagt område utan tillstånd', 'OL 3 kap.', 'bot', 5000, 0),
  -- Allmän ordning (ordningslagen och lokala ordningsföreskrifter)
  ('ORD-001', 'public_order', 'Alkoholförtäring på allmän plats', 'Lokala ordningsföreskrifter (OL 3 kap.)', 'ordningsbot', 800, 0),
  ('ORD-002', 'public_order', 'Urinering på allmän plats', 'Lokala ordningsföreskrifter (OL 3 kap.)', 'ordningsbot', 800, 0),
  ('ORD-003', 'public_order', 'Nedskräpning', 'Miljöbalken 29 kap. 7 §', 'ordningsbot', 800, 0),
  ('ORD-004', 'public_order', 'Användning av fyrverkerier utan tillstånd', 'OL 3 kap. 7 §', 'ordningsbot', 1500, 0),
  ('ORD-005', 'public_order', 'Störande av allmän ordning', 'OL 3 kap.', 'bot', 2000, 0),
  ('ORD-006', 'public_order', 'Offentlig tillställning utan tillstånd', 'OL 2 kap. 4 §', 'bot', 5000, 0),
  ('ORD-007', 'public_order', 'Maskering vid allmän sammankomst', 'Lag (2005:900) om förbud mot att bära maskering i vissa fall', 'bot', 3000, 0),
  ('ORD-008', 'public_order', 'Brott mot tillträdesförbud vid idrottsarrangemang', 'Lag (2005:321) om tillträdesförbud vid idrottsarrangemang', 'bot', 3000, 0),
  ('ORD-009', 'public_order', 'Störande buller på allmän plats', 'Lokala ordningsföreskrifter (OL 3 kap.)', 'ordningsbot', 1000, 0),
  ('ORD-010', 'public_order', 'Olovlig försäljning på allmän plats', 'OL 3 kap.', 'ordningsbot', 1500, 0),
  -- Övrigt
  ('OVR-001', 'other', 'Olovlig försäljning av alkohol', 'Alkohollagen (2010:1622) 11 kap.', 'bot', 6000, 0),
  ('OVR-002', 'other', 'Olovlig tillverkning av alkohol (hembränning)', 'Alkohollagen (2010:1622) 11 kap.', 'bot', 5000, 0),
  ('OVR-003', 'other', 'Langning av alkohol', 'Alkohollagen (2010:1622) 11 kap.', 'bot', 4000, 0),
  ('OVR-004', 'other', 'Penningtvättsbrott', 'Lag (2014:307) om straff för penningtvättsbrott 3 §', 'fängelse', 10000, 15),
  ('OVR-005', 'other', 'Grovt penningtvättsbrott', 'Lag (2014:307) om straff för penningtvättsbrott', 'fängelse', 20000, 30),
  ('OVR-006', 'other', 'Smuggling', 'Lag (2000:1225) om straff för smuggling 3 §', 'bot', 5000, 0),
  ('OVR-007', 'other', 'Grov smuggling', 'Lag (2000:1225) om straff för smuggling 5 §', 'fängelse', 15000, 20),
  ('OVR-008', 'other', 'Jaktbrott', 'Jaktlagen (1987:259) 43 §', 'bot', 5000, 0)
ON DUPLICATE KEY UPDATE
  -- updated_at first, while the columns still hold their old values (assignments run left to right): it moves only
  -- when a value really changes, like the ON UPDATE clause that UTC tables cannot have (docs/contracts.md §C7).
  updated_at = IF(BINARY category <=> BINARY VALUES(category) AND BINARY title_sv <=> BINARY VALUES(title_sv)
    AND BINARY law_ref <=> BINARY VALUES(law_ref) AND BINARY class <=> BINARY VALUES(class)
    AND fine <=> VALUES(fine) AND jail_min <=> VALUES(jail_min), updated_at, UTC_TIMESTAMP()),
  category = VALUES(category),
  title_sv = VALUES(title_sv),
  law_ref = VALUES(law_ref),
  class = VALUES(class),
  fine = VALUES(fine),
  jail_min = VALUES(jail_min);
