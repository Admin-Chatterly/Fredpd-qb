-- SPDX-License-Identifier: GPL-3.0-only
-- Report templates (fredpd_report_templates, 003_records.sql): Swedish markdown-lite skeletons offered by the report
-- editor (listReportTemplates; unit NULL = every unit). Markdown-lite = # heading, **bold**, - list; rendered as text.
-- Ids 1-99 belong to this seed and are updated in place when it changes (seeds are the source of truth,
-- docs/modules/db.md); templates made in the admin UI get AUTO_INCREMENT ids and are never touched. A template is
-- retired with active = 0, which this seed never writes.

INSERT INTO fredpd_report_templates (id, name, unit, body) VALUES
  (1, 'Anmälan', NULL, '# Anmälan

**Brott:**
**Tid för händelsen:**
**Plats:**

## Målsägande
- Namn:
- Personnummer:
- Telefon:

## Misstänkt
- Namn / signalement:

## Händelseförlopp


## Skador och egendom
-

## Vittnen
-

## Åtgärder
- '),
  (2, 'PM', NULL, '# Promemoria

**Ämne:**
**Datum:**

## Bakgrund


## Iakttagelser


## Bedömning


## Förslag till åtgärd
- '),
  (3, 'Beslagsprotokoll', NULL, '# Beslagsprotokoll

**Beslagsdatum:**
**Plats:**
**Beslag hos (namn, personnummer):**
**Beslagsbeslut fattat av:**

## Beslagtagen egendom
- Nr 1:
- Nr 2:

## Skäl för beslag
- [ ] Bevisbeslag
- [ ] Förverkandebeslag
- [ ] Återställandebeslag

## Förvaring
**Förvaringsplats / bevisförråd:**
**Beslagets innehavare underrättad:** Ja / Nej'),
  (4, 'Förhör', NULL, '# Förhörsprotokoll

**Förhörd (namn, personnummer):**
**Förhörd i egenskap av:** Misstänkt / Målsägande / Vittne
**Tid och plats för förhöret:**
**Förhörsledare:**
**Närvarande:**

## Underrättelser
- Underrättad om misstanke:
- Rätt till försvarare:

## Förhöret


## Genomläst och godkänt
Förhöret har lästs upp / lästs igenom av den hörde och godkänts: Ja / Nej')
ON DUPLICATE KEY UPDATE
  name = VALUES(name),
  unit = VALUES(unit),
  body = VALUES(body);
