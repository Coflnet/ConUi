# Relationship matching cases

This independently specified corpus adds 116 synthetic English and German relationship cases to the existing 50 extraction cases. All names and stories are fictional. The machine-readable expectations live in `flutter_app/test/fixtures/transcript_relationship_cases.json`; `flutter_app/test/services/transcript_relationship_cases_test.dart` runs every case.

An arrow reads **from is the type of to**. Tests compare the complete set of directed endpoints and types, including the absence of extra relationships and duplicate inverse or alias edges. Output order is immaterial. Each returned relationship must cite a nonempty literal substring of the original transcript; an implicit clause can cite its original phrase without inventing a subject in the evidence. Generic person facts are outside this corpus and remain covered by the existing extraction tests.

Existing people are optional fixture inputs. Uniquely resolved aliases compare by `id:` identity. An ambiguous first name remains a surface name here: the parser must not choose between existing IDs; the controller review flow resolves that choice. General pronouns do not license inferred endpoints.

## Families

| Family | Cases |
| --- | ---: |
| care-and-mentorship | 16 |
| extended-family | 14 |
| household-school-work | 21 |
| natural-and-attribution | 18 |
| named-lists | 8 |
| identity | 6 |
| hard-negatives | 29 |
| scope | 4 |

## Cases

Expectations describe semantic intent independently of parser output. Blank relationships mean no relationship suggestion, even if an ordinary person fact is supported. Validation on 2026-10-28: **116/116 cases pass** with `flutter test test/services/transcript_relationship_cases_test.dart`. This result covers local extraction only; saving suggestions and resolving ambiguous existing people require the controller and browser tests.

| ID | Language | Story | Expected relationships | Rationale |
| --- | --- | --- | --- | --- |
| r001 | en | Anna is the adoptive mother of Ben. | Anna → Ben (adoptiveParent) |  |
| r002 | de | Anna ist die Adoptivtochter von Ben. | Anna → Ben (adoptedChild) |  |
| r003 | de | Anna ist die Adoptivmutter von Ben. | Anna → Ben (adoptiveParent) |  |
| r004 | en | Anna is Ben’s adopted son. | Anna → Ben (adoptedChild) |  |
| r005 | en | Anna is the godmother of Ben. | Anna → Ben (godparent) |  |
| r006 | de | Anna ist das Patenkind von Ben. | Anna → Ben (godchild) |  |
| r007 | de | Bens Patentante ist Anna. | Anna → Ben (godparent) |  |
| r008 | en | Anna is Ben's godchild. | Anna → Ben (godchild) |  |
| r009 | en | Anna is the guardian of Ben. | Anna → Ben (guardian) |  |
| r010 | de | Anna ist das Mündel von Ben. | Anna → Ben (ward) |  |
| r011 | de | Anna ist der Vormund von Ben. | Anna → Ben (guardian) |  |
| r012 | en | Ben's ward is Anna. | Anna → Ben (ward) |  |
| r013 | en | Anna is Ben's mentor. | Anna → Ben (mentor) |  |
| r014 | de | Anna ist die Mentorin von Ben. | Anna → Ben (mentor) |  |
| r015 | en | Anna is the mentee of Ben. | Anna → Ben (mentee) |  |
| r016 | de | Anna ist der Mentee von Ben. | Anna → Ben (mentee) |  |
| r017 | en | Anna is the aunt of Ben. | Anna → Ben (auntOrUncle) |  |
| r018 | de | Anna ist der Onkel von Ben. | Anna → Ben (auntOrUncle) |  |
| r019 | en | Ben's niece is Anna. | Anna → Ben (nieceOrNephew) |  |
| r020 | de | Anna ist der Neffe von Ben. | Anna → Ben (nieceOrNephew) |  |
| r021 | en | Anna and Ben are cousins. | Anna → Ben (cousin) |  |
| r022 | de | Anna ist die Cousine von Ben. | Anna → Ben (cousin) |  |
| r023 | en | Anna is Ben's mother-in-law. | Anna → Ben (parentInLaw) |  |
| r024 | de | Anna ist der Schwiegervater von Ben. | Anna → Ben (parentInLaw) |  |
| r025 | en | Anna is the son-in-law of Ben. | Anna → Ben (childInLaw) |  |
| r026 | de | Bens Schwiegertochter ist Anna. | Anna → Ben (childInLaw) |  |
| r027 | en | Anna is the sister-in-law of Ben. | Anna → Ben (siblingInLaw) |  |
| r028 | de | Anna ist der Schwager von Ben. | Anna → Ben (siblingInLaw) |  |
| r029 | en | Anna is Ben’s stepsister. | Anna → Ben (stepSibling) |  |
| r030 | de | Anna und Ben sind Stiefgeschwister. | Anna → Ben (stepSibling) |  |
| r031 | en | Anna and Ben are roommates. | Anna → Ben (roommate) |  |
| r032 | de | Anna ist die Mitbewohnerin von Ben. | Anna → Ben (roommate) |  |
| r033 | en | Anna is Ben's classmate. | Anna → Ben (classmate) |  |
| r034 | de | Anna und Ben sind Klassenkameraden. | Anna → Ben (classmate) |  |
| r035 | en | Anna is the teammate of Ben. | Anna → Ben (teammate) |  |
| r036 | de | Anna ist die Teamkollegin von Ben. | Anna → Ben (teammate) |  |
| r037 | en | Anna is the manager of Ben. | Anna → Ben (manager) |  |
| r038 | de | Bens Vorgesetzte ist Anna. | Anna → Ben (manager) |  |
| r039 | en | Anna is Ben's direct report. | Anna → Ben (directReport) |  |
| r040 | de | Anna ist Ben direkt unterstellt. | Anna → Ben (directReport) |  |
| r041 | en | Anna is the teacher of Ben. | Anna → Ben (teacher) |  |
| r042 | de | Anna ist die Lehrerin von Ben. | Anna → Ben (teacher) |  |
| r043 | en | Ben's student is Anna. | Anna → Ben (student) |  |
| r044 | de | Anna ist die Schülerin von Ben. | Anna → Ben (student) |  |
| r045 | en | Anna and Ben are business partners. | Anna → Ben (businessPartner) |  |
| r046 | de | Anna ist die Geschäftspartnerin von Ben. | Anna → Ben (businessPartner) |  |
| r047 | en | Anna adopted Ben. | Anna → Ben (adoptiveParent) |  |
| r048 | de | Anna hat Ben adoptiert. | Anna → Ben (adoptiveParent) |  |
| r049 | en | Anna mentors Ben. | Anna → Ben (mentor) |  |
| r050 | de | Anna betreut Ben als Mentorin. | Anna → Ben (mentor) |  |
| r051 | en | Anna teaches Ben. | Anna → Ben (teacher) |  |
| r052 | de | Anna unterrichtet Ben. | Anna → Ben (teacher) |  |
| r053 | en | Ben reports to Anna. | Ben → Anna (directReport) |  |
| r054 | de | Ben berichtet an Anna. | Ben → Anna (directReport) |  |
| r055 | en | Anna is married to Ben. | Anna → Ben (spouse) |  |
| r056 | de | Anna ist mit Ben verheiratet. | Anna → Ben (spouse) |  |
| r057 | en | Ben’s grandfather is Anna. | Anna → Ben (grandparent) |  |
| r058 | de | Bens Enkelin ist Anna. | Anna → Ben (grandchild) |  |
| r059 | en | Anna, Ben's aunt, lives in Leeds. | Anna → Ben (auntOrUncle) |  |
| r060 | de | Anna, die Schwiegermutter von Ben, wohnt in Bonn. | Anna → Ben (parentInLaw) |  |
| r061 | en | Anna, the guardian of Ben, works at Atlas. | Anna → Ben (guardian) |  |
| r062 | de | Anna, Bens Mentorin, wohnt in Köln. | Anna → Ben (mentor) |  |
| r063 | en | Anna is the acquaintance of Ben. | Anna → Ben (acquaintance) |  |
| r064 | de | Anna ist die Ex-Partnerin von Ben. | Anna → Ben (exPartner) |  |
| r065 | en | Anna, Ben and Clara are friends. | Anna → Ben (friend); Anna → Clara (friend); Ben → Clara (friend) |  |
| r066 | de | Anna, Ben und Clara sind Geschwister. | Anna → Ben (sibling); Anna → Clara (sibling); Ben → Clara (sibling) |  |
| r067 | en | Anna is the mother of Ben and Clara. | Anna → Ben (parent); Anna → Clara (parent) |  |
| r068 | de | Anna ist die Tante von Ben und Clara. | Anna → Ben (auntOrUncle); Anna → Clara (auntOrUncle) |  |
| r069 | en | Anna and Ben are the parents of Clara. | Anna → Clara (parent); Ben → Clara (parent) |  |
| r070 | de | Anna und Ben sind Eltern von Clara. | Anna → Clara (parent); Ben → Clara (parent) |  |
| r071 | en | Anna is the teacher of Ben, Clara and David. | Anna → Ben (teacher); Anna → Clara (teacher); Anna → David (teacher) |  |
| r072 | de | Anna, Ben und Clara sind Mitbewohner. | Anna → Ben (roommate); Anna → Clara (roommate); Ben → Clara (roommate) |  |
| r073 | en | Anni is the mentor of Ben. | id:anna → id:ben (mentor) |  |
| r074 | de | Anna Weber ist die Mentorin von Benjamin Roth. Anni ist die Mentorin von Ben. | id:anna → id:ben (mentor) | Aliases must not duplicate one relationship. |
| r075 | en | Anni is the friend of Anna Weber. | None | Two names of the same person cannot create a self edge. |
| r076 | de | Anna ist die Freundin von Anna. | None | Identical new names cannot create a self edge. |
| r077 | en | Alex is the friend of Ben. | Alex → id:ben (friend) | The surface mention stays ambiguous; controller review must choose the existing person. |
| r078 | de | Élodie ist die Nachbarin von Anne-Marie. | Élodie → Anne-Marie (neighbour) |  |
| r079 | en | Anna and Ben live together in London. | None | Shared residence does not establish romance. |
| r080 | de | Anna und Ben arbeiten bei Atlas. | None | Coemployment does not establish friendship or a direct reporting line. |
| r081 | en | Anna works at Ben. | None | An employer named Ben is not a person endpoint. |
| r082 | de | Anna hat einen Hund namens Ben. | None | A named animal is not a person endpoint. |
| r083 | en | Anna is not the guardian of Ben. | None | Negated role. |
| r084 | de | Anna ist keine Lehrerin von Ben. | None | Negated role. |
| r085 | en | Anna might be the aunt of Ben. | None | Modal uncertainty. |
| r086 | de | Vielleicht ist Anna die Mutter von Ben. | None | Explicit uncertainty. |
| r087 | en | If Anna is the mentor of Ben, Clara will help. | None | Conditional scope. |
| r088 | de | Falls Anna die Tante von Ben ist, kommt Clara. | None | Conditional scope. |
| r089 | en | Clara says Anna is the mother of Ben. | None | Reported claim. |
| r090 | de | Clara behauptet, Anna ist die Tante von Ben. | None | Reported claim. |
| r091 | en | "Anna is the mother of Ben." | None | A quotation alone is not an asserted current relationship. |
| r092 | de | „Anna ist die Mutter von Ben.“ | None | Quoted claim. |
| r093 | en | Is Anna the teacher of Ben? | None | Question. |
| r094 | de | Ist Anna die Mutter von Ben? | None | Question. |
| r095 | en | Anna will marry Ben. | None | Future marriage is not a current spouse relationship. |
| r096 | de | Anna wird Ben heiraten. | None | Future marriage. |
| r097 | en | Anna was married to Ben. | None | Historical marriage does not establish a current spouse. |
| r098 | de | Anna war mit Ben verheiratet. | None | Historical marriage. |
| r099 | en | Anna met Clara. She is the sister of Ben. | None | Ambiguous general pronoun. |
| r100 | de | Anna traf Clara. Sie ist die Schwester von Ben. | None | Ambiguous general pronoun. |
| r101 | en | Anna is the friend of the company Atlas. | None | An explicitly described company is not a person. |
| r102 | de | Anna ist die Freundin des Hundes Ben. | None | An explicitly described pet is not a person. |
| r103 | en | Anna and Ben play tennis. | None | A shared activity does not establish teammate or friendship. |
| r104 | de | Anna und Ben besuchen dieselbe Schule. | None | Same school does not establish classmate. |
| r105 | en | Anna is not the aunt of Ben. Clara is the cousin of David. | Clara → David (cousin) |  |
| r106 | de | Anna ist vielleicht die Mutter von Ben. Clara ist die Lehrerin von David. | Clara → David (teacher) |  |
| r107 | en | Anna is the mother of Ben. Ben is the son of Anna. | Anna → Ben (parent) | Inverse wording must not duplicate the same fact. |
| r108 | de | Anna und Ben sind Geschäftspartner. Anna ist die Schwester von Clara. | Anna → Ben (businessPartner); Anna → Clara (sibling) | Business partnership must not add a romantic partner edge. |
| r109 | en | Anna is the employer of Ben. | Anna → Ben (employer) | An employer is not necessarily a direct manager. |
| r110 | de | Anna ist der Arbeitgeber von Ben. | Anna → Ben (employer) | Named employer inverse of employee. |
| r111 | en | Anna is the employee of Ben. | Anna → Ben (employee) | Employment does not establish a direct reporting line. |
| r112 | de | Anna ist der Mitarbeiter von Ben. | Anna → Ben (employee) | Mitarbeiter means employee, not necessarily direct report. |
| r113 | en | Anna is Ben's chef. | None | English chef describes a cook and must not match German Chef (manager). |
| r114 | de | Anna ist Bens Chef. | Anna → Ben (manager) | German Chef describes a manager, unlike English chef. |
| r115 | en | Anna is the former colleague of Ben. | None | A former colleague does not establish a current colleague relationship. |
| r116 | de | Anna ist die ehemalige Kollegin von Ben. | None | An explicitly former role must not become a current colleague relationship. |

## Run locally

```sh
cd flutter_app
flutter test test/services/transcript_relationship_cases_test.dart
```
