import { Component, HostListener, OnInit, ViewChild, signal } from '@angular/core';
import { NgSelectComponent, NgSelectModule } from '@ng-select/ng-select';
import { catchError, concat, distinctUntilChanged, Observable, of, Subject, switchMap, tap } from 'rxjs';
import { PersonAttributeDto, PersonService, SearchResult, SearchService, PersonFullView } from '../client';
import { FormControl, FormsModule, ReactiveFormsModule } from '@angular/forms';
import { CommonModule } from '@angular/common';
import { ActivatedRoute, Router } from '@angular/router';
import { FieldComponent } from '../field/field.component';
import { MatAutocompleteModule } from '@angular/material/autocomplete';
import { MatInputModule } from '@angular/material/input';
import { MatButtonModule } from '@angular/material/button';
import { MatFormFieldModule } from '@angular/material/form-field';


@Component({
    selector: 'app-editor',
    templateUrl: './editor.component.html',
    host: { ngSkipHydration: "true" },
    imports: [
        CommonModule,
        FormsModule,
        ReactiveFormsModule,
        NgSelectModule,
        FieldComponent,
        MatAutocompleteModule,
        MatInputModule,
    MatButtonModule,
    MatFormFieldModule
    ],
    styleUrls: ['./editor.component.scss']
})
export class EditorComponent implements OnInit {

  people$: Observable<SearchResult[]> = of([]);
  peopleLoading = false;
  peopleInput$ = new Subject<string>();
  selectedPerson: SearchResult | null = null;
  personData: PersonAttributeDto[] = [];
  personName: string = '';
  personFull = signal<PersonFullView | null>(null);
  @ViewChild('searchBar', { static: true })
  searchBar: NgSelectComponent = null!;
  newFieldControl = new FormControl('');
  options: string[] = ['Geburtstag', 'Bruder', 'Schwester', 'Mutter', 'Vater', 'Sohn', 'Tochter', 'Telefonnummer',
    'E-Mail', 'Adresse', 'Geschlecht', 'Beruf', 'Hobby', 'Kontakt', 'Notizen'];
  subscription: any;

  @HostListener('document:keydown', ['$event'])
  handleKeyboardEvent(event: KeyboardEvent) {
    console.log('key', event);
    if (event.key === 'f' && event.ctrlKey) {
      if (!this.searchBar.focused)
        event.preventDefault();
      this.searchBar.focus();
    }
  }

  constructor(private searchService: SearchService,
    private person: PersonService,
    private router: Router,
    private activeRoute: ActivatedRoute
  ) {
    activeRoute.params.subscribe(params => {
      var id = params['person'];
      if (!id)
        return;
      // Use getPersonFull to get complete person data including relationships
      person.getPersonFull(id).subscribe(fullPerson => {
        this.personFull.set(fullPerson);
        this.personName = fullPerson.name ?? '' as any;
        // Convert attributes dictionary to PersonAttributeDto array
        if (fullPerson.attributes) {
          this.personData = Object.entries(fullPerson.attributes).map(([key, value]) => ({
            personId: fullPerson.personId ?? null,
            category: 'personal',
            key,
            value
          }));
        } else {
          this.personData = [];
        }
      });
      console.log("params", id);
    });
  }

  ngOnInit() {
    this.loadPeople();
    this.searchBar.focus();
  }

  trackByFn(item: SearchResult) {
    return (item.name ?? '') + (item.id ?? '');
  }

  addField() {
    var newFieldName = this.newFieldControl.value;
    if (!newFieldName)
      return;
    this.addNamedField(newFieldName);
  }

  public addNamedField(newFieldName: string) {
    this.personData.push({ personId: this.selectedPerson?.id ?? null, category: 'personal', key: newFieldName, value: '' });
    this.newFieldControl.setValue('');
  }

  selected(event: FocusEvent) {
    console.log("selected", event);
  }

  change(event: FocusEvent) {
    console.log("change", event);
    console.log("selectedPerson", this.selectedPerson);
    this.personData = [];
    this.personFull.set(null);
    if (!this.selectedPerson?.id) {
      // create person (temporary inline attribute for name)
      this.personName = this.selectedPerson?.name ?? '';
      this.personData.push({ personId: null, category: 'personal', key: 'name', value: this.personName });
      return;
    }
    // Use getPersonFull to get complete person data
    this.person.getPersonFull(this.selectedPerson.id).subscribe((fullPerson: PersonFullView) => {
      this.personFull.set(fullPerson);
      this.personName = fullPerson.name ?? '' as any;
      // Convert attributes dictionary to PersonAttributeDto array
      if (fullPerson.attributes) {
        this.personData = Object.entries(fullPerson.attributes).map(([key, value]) => ({
          personId: fullPerson.personId ?? null,
          category: 'personal',
          key,
          value
        }));
      } else {
        this.personData = [];
      }
    });
  }

  onFieldSaved(response: any, field: PersonAttributeDto) {
    // If backend returned created person id or updated attribute, try to refresh the person view
    if (response && response.personId) {
      // If person was created, set selectedPerson id so future edits are attached
      if (!this.selectedPerson) {
        this.selectedPerson = { id: response.personId, name: this.personData.find(f => f.key === 'name')?.value ?? 'Unnamed' } as any;
      } else if (!this.selectedPerson.id) {
        this.selectedPerson.id = response.personId;
      }
      // reload full person
      this.person.getPersonFull(response.personId).subscribe((fullPerson: PersonFullView) => {
        this.personFull.set(fullPerson);
        if (fullPerson.attributes) {
          this.personData = Object.entries(fullPerson.attributes).map(([key, value]) => ({
            personId: fullPerson.personId ?? null,
            category: 'personal',
            key,
            value
          }));
        }
      });
    } else if (response && response.error) {
      // TODO: surface an inline error to the user
      console.error('Field save error', response.error);
    } else {
      // generic refresh: if we have a selectedPerson with id, reload attributes
      if (this.selectedPerson?.id) {
        this.person.getPersonFull(this.selectedPerson.id).subscribe((fullPerson: PersonFullView) => {
          this.personFull.set(fullPerson);
          if (fullPerson.attributes) {
            this.personData = Object.entries(fullPerson.attributes).map(([key, value]) => ({
              personId: fullPerson.personId ?? null,
              category: 'personal',
              key,
              value
            }));
          }
        });
      }
    }
  }

  saveAll() {
    // If there's no selected person id, we may need to create the person by posting the name field first
    const nameField = this.personData.find(f => f.key === 'name');
    const nameValue = this.personName || nameField?.value;
    if ((!this.selectedPerson || !this.selectedPerson.id) && nameValue) {
      // create person by posting name attribute; backend will create person and return personId
      const nf: PersonAttributeDto = { personId: null, category: 'personal', key: 'name', value: nameValue };
      this.person.addPersonData(nf).subscribe({
        next: (res) => {
          // res may contain personId
          this.onFieldSaved(res, nf);
        },
        error: (err) => console.error('Create person failed', err)
      });
    }

    // Save all other fields
    for (const f of this.personData) {
      // attach personId if we have it
      if (this.selectedPerson?.id) f.personId = this.selectedPerson.id;
      this.person.addPersonData(f).subscribe({ next: () => { /* no-op */ }, error: (e) => console.error('Failed saving', f, e) });
    }
  }

  private loadPeople() {
    this.people$ = concat(
      of([]), // default items
      this.peopleInput$.pipe(
        distinctUntilChanged(),
        tap(() => this.peopleLoading = true),
        switchMap(term => this.searchService.search(term).pipe(
          catchError(() => of([])), // empty list on error
          tap(() => this.peopleLoading = false)
        ))
      )
    );
  }
}
