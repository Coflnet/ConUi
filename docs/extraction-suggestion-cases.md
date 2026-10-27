# 50 synthetic extraction suggestion cases

Created and evaluated on 2026-10-27. All 50 desired behaviors are now covered by the regular regression suite. All names, addresses, and contact details are synthetic. Each case starts with no existing people.

**Current result: 50/50 exact expected-output matches.** The baseline matched 34 cases, produced incomplete or misleading suggestions in six, and missed useful facts in ten. The implementation addresses all 16 gaps.

Baseline parser revision: `d629d81ec535e902b2c76f51c161e9add1888ac6` (unchanged at `4226e68`). The updated parser preserves address punctuation, handles bounded same-sentence residence corrections, scopes independent contrast clauses, and supports the additional explicit fact categories below. These are local parser results; browser persistence is checked separately by `deployment/e2e/extraction.py`.

## All 50 cases

“Match” means the person, relationship direction/type, fact value, employer flag, source text, output order, and absence of extra suggestions match the fixture exactly. Semantically equivalent wording or evidence boundaries can therefore still require review. Relationship arrows read “from is the type of to.” Generic facts retain the parser’s clause wording; they do not update structured contact fields.

| # | Story text | Expected suggestions | Current result |
| --- | --- | --- | --- |
| 01 | Nora wohnt in der Lindenstraße 17a. | Nora → Nora wohnt in der Lindenstraße 17a | Match |
| 02 | Mara König wohnt in der Gartenstraße 8 in 04109 Leipzig. | Mara König → Mara König wohnt in der Gartenstraße 8 in 04109 Leipzig | Match |
| 03 | Olivia ist die Schwester von Paul, der in Dresden wohnt. | Olivia → Paul (sibling); Paul → Paul in Dresden wohnt | Match |
| 04 | David lives at 17 Main Street, Apartment 4B. | David → David lives at 17 Main Street, Apartment 4B | Match |
| 05 | Clara wohnt in Dr.-Müller-Straße 7. | Clara → Clara wohnt in Dr.-Müller-Straße 7 | Match |
| 06 | Sara wohnt in Ulm. Tim wohnt in Kiel. | Sara → Sara wohnt in Ulm; Tim → Tim wohnt in Kiel | Match |
| 07 | Greta arbeitet bei Bosch und wohnt in Ulm. | Greta → employer: Bosch; Greta → Greta wohnt in Ulm | Match |
| 08 | Hugo wohnte früher in Bonn. | Hugo → Hugo wohnte früher in Bonn | Match |
| 09 | Iris ist nach Hamburg gezogen. | Iris → Iris ist nach Hamburg gezogen | Match |
| 10 | Jana zieht nächsten Monat nach Bremen. | Jana → Jana zieht nächsten Monat nach Bremen | Match |
| 11 | Farid works for Oak & Sons. | Farid → employer: Oak & Sons | Match |
| 12 | Eva arbeitet bei Nordlicht GmbH. | Eva → employer: Nordlicht GmbH | Match |
| 13 | Lea is the colleague of Noah, who works at Acme. | Lea → Noah (colleague); Noah → employer: Acme | Match |
| 14 | Quinn bought a new car. | Quinn → Quinn bought a new car | Match |
| 15 | Rita kaufte ein neues Auto. | Rita → Rita kaufte ein neues Auto | Match |
| 16 | Eva ist Zahnärztin. | Eva → Eva ist Zahnärztin | Match |
| 17 | Greta spielt jeden Donnerstag Volleyball. | Greta → Greta spielt jeden Donnerstag Volleyball | Match |
| 18 | Jana hat einen Hund namens Milo. | Jana → Jana hat einen Hund namens Milo | Match |
| 19 | Mara hat am 12. März 1992 Geburtstag. | Mara → Mara hat am 12. März 1992 Geburtstag | Match |
| 20 | Noah hat die Telefonnummer 030 123456. | Noah → Noah hat die Telefonnummer 030 123456 | Match |
| 21 | Lena ist die Mutter von Emil. | Lena → Emil (parent) | Match |
| 22 | Lena ist die Mutter von Emil. Emil ist der Sohn von Lena. | Lena → Emil (parent) | Match |
| 23 | Nora ist mit Emil verheiratet. | Nora → Emil (spouse) | Match |
| 24 | Karl ist der Großvater von Lena. | Karl → Lena (grandparent) | Match |
| 25 | Lena is the stepdaughter of Karl. | Lena → Karl (stepChild) | Match |
| 26 | Farid ist der Halbbruder von Greta. | Farid → Greta (halfSibling) | Match |
| 27 | Olivia und Paul sind Nachbarn. | Olivia → Paul (neighbour) | Match |
| 28 | Hans’ Tochter ist Nora. | Nora → Hans (child) | Match |
| 29 | Élodie is a friend of Liam O’Connor. | Élodie → Liam O’Connor (friend) | Match |
| 30 | Meine Schwester Nora ist die Mutter von Emil. | Nora → Emil (parent) | Match |
| 31 | Quinn, Rita’s colleague, works at Acme. | Quinn → Rita (colleague); Quinn → employer: Acme | Match |
| 32 | Olivia is Paul’s sister, who lives in Oxford. | Olivia → Paul (sibling); Olivia → Olivia lives in Oxford | Match |
| 33 | Nora ist mit Emil verheiratet, der bei Siemens arbeitet. | Nora → Emil (spouse); Emil → employer: Siemens | Match |
| 34 | Sara works at Bosch and Tim lives in Ulm. | Sara → employer: Bosch; Tim → Tim lives in Ulm | Match |
| 35 | Karl und Lena wohnen zusammen in Berlin. | Karl → Karl und Lena wohnen zusammen in Berlin; Lena → Karl und Lena wohnen zusammen in Berlin | Match |
| 36 | Nora wohnt nicht mehr in Hamburg. | No suggestion | Match |
| 37 | Nora wohnt in Berlin? | No suggestion | Match |
| 38 | Nora wohnt vielleicht in Berlin. | No suggestion | Match |
| 39 | Nora wohnt in Berlin, möglicherweise. | No suggestion | Match |
| 40 | Nora lives in Berlin, reportedly. | No suggestion | Match |
| 41 | Wenn Nora in Berlin wohnt, ist Emil ihr Nachbar. | No suggestion | Match |
| 42 | Eva met Farah. She lives in Leipzig. | No suggestion | Match |
| 43 | Eva traf Farah. Sie wohnt in Leipzig. | No suggestion | Match |
| 44 | Nora wohnt in Berlin oder Hamburg. | No suggestion | Match |
| 45 | Nora arbeitet bei Acme oder Beta. | No suggestion | Match |
| 46 | Nora wohnt in Bonn, nein, in Köln. | Nora → Nora wohnt in Köln | Match |
| 47 | Nora wohnt nicht in Bonn, aber Emil wohnt in Köln. | Emil → Emil wohnt in Köln | Match |
| 48 | Das Museum wohnt in Berlin. | No suggestion | Match |
| 49 | Nora ist die Schwester von Nora. | No suggestion | Match |
| 50 | Nora ist die Schwester von Emil oder Paul. | No suggestion | Match |

## Baseline gaps addressed

| # | Improvement | Previous output |
| --- | --- | --- |
| 04 | Keep the entire address, including the apartment. | David → David lives at 17 Main Street |
| 05 | A period inside a street name must not end the fact. | Clara → Clara wohnt in Dr |
| 08 | Preserve the past tense; do not turn this into a current address. | No suggestion |
| 09 | Residence: relocation | No suggestion |
| 10 | Preserve the future qualifier; do not overwrite a current address. | No suggestion |
| 16 | Profession | No suggestion |
| 17 | Hobby | No suggestion |
| 18 | Milo is a pet, not a newly inferred person. | No suggestion |
| 19 | Birthday: German date | No suggestion |
| 20 | Suggest a sourced fact; do not silently replace contact fields. | No suggestion |
| 35 | Attribute the shared residence to both; infer no romantic relationship. | No suggestion |
| 39 | Do not retain the preceding clause as an affirmative fact. | Nora → Nora wohnt in Berlin |
| 44 | Two alternatives do not establish a definite residence. | Nora → Nora wohnt in Berlin oder Hamburg |
| 45 | Do not propose the combined phrase as a company name. | Nora → employer: Acme oder Beta |
| 46 | Keep the corrected city; never suggest the retracted Bonn claim. | Nora → Nora wohnt in Bonn |
| 47 | Suppress only the negated claim, retaining Emil’s explicit fact. | No suggestion |

The accuracy fixes cover 04/05 (address truncation), 39 (uncertainty), 44/45 (unresolved alternatives), 46 (a retracted city), and 47 (an independent affirmative claim beside negation). Additional adversarial regressions cover shared residences followed by another person’s employer, punctuation without spaces, May in names/dates, address floor abbreviations, company conjunctions, and coordinated relationship clauses.

Case 36 follows the current affirmative-only suggestion policy: a negated residence must not become a current residence claim. It does not assert that negative facts can never be useful personal notes. Case 35 records a shared residence for both named people without inventing a romantic relationship. Pet names in case 18 must not create people. Past and future facts in 08–10 must preserve their qualifiers.

## Reproduce

The [JSON fixture](../flutter_app/test/fixtures/transcript_extraction_cases.json) contains the complete expected output, including attribution and source evidence. Run from `flutter_app`:

```sh
flutter test --no-pub test/services/transcript_extraction_cases_test.dart
```

The [regression test](../flutter_app/test/services/transcript_extraction_cases_test.dart) now runs in the normal `flutter test` suite. No challenge cases are skipped. Expected values and original evidence remain in the JSON fixture; failures report their mismatched output.

When extending extraction, preserve these desired expectations, review the source evidence for every affected case, and rerun the existing parser/person-mention tests. Do not change an expectation solely to match an incorrect current output.
