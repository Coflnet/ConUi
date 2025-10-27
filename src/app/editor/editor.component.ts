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
    // Support routes that use either :id (app.routes.ts) or :person (legacy)
    activeRoute.params.subscribe(params => {
      const id = params['id'] ?? params['person'];
      if (!id) return;

      // Load the full person view and populate editor state
      this.person.getPersonFull(id).subscribe(fullPerson => {
        this.personFull.set(fullPerson);
        this.personName = fullPerson.name ?? '' as any;

        // Preserve any unsaved local fields (personId == null) so user doesn't lose in-progress edits
        const localUnsaved = this.personData.filter(f => !f.personId);

        // Convert attributes dictionary to PersonAttributeDto array
        const serverAttrs = fullPerson.attributes
          ? Object.entries(fullPerson.attributes).map(([key, value]) => ({
              personId: fullPerson.personId ?? null,
              category: 'personal',
              key,
              value
            }))
          : [];

        this.personData = [...serverAttrs, ...localUnsaved];

        // Ensure the ng-select shows the loaded person
        this.selectedPerson = { id: fullPerson.personId ?? id, name: fullPerson.name } as any;
      });

      console.log('params', id);
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
      const localUnsaved = this.personData.filter(f => !f.personId);
      const serverAttrs = fullPerson.attributes
        ? Object.entries(fullPerson.attributes).map(([key, value]) => ({
            personId: fullPerson.personId ?? null,
            category: 'personal',
            key,
            value
          }))
        : [];
      this.personData = [...serverAttrs, ...localUnsaved];
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

      // Ensure unsaved local fields get the returned personId so future saves attach correctly
      for (const f of this.personData) {
        if (!f.personId) f.personId = response.personId;
      }

      // Merge server attributes into existing personData without dropping local unsaved fields
      this.person.getPersonFull(response.personId).subscribe((fullPerson: PersonFullView) => {
        this.personFull.set(fullPerson);
        const serverAttrs = fullPerson.attributes
          ? Object.entries(fullPerson.attributes).map(([key, value]) => ({
              personId: fullPerson.personId ?? null,
              category: 'personal',
              key,
              value
            }))
          : [];

        // Update existing fields with server values, add missing server fields, keep local unsaved ones
        const merged: PersonAttributeDto[] = [];
        const localByKey = new Map(this.personData.map(f => [f.key, f]));
        for (const sa of serverAttrs) {
          const existing = localByKey.get(sa.key);
          if (existing) {
            existing.value = sa.value;
            existing.personId = sa.personId;
            merged.push(existing);
            localByKey.delete(sa.key);
          } else {
            merged.push(sa);
          }
        }
        // append any remaining local (unsaved) fields
        for (const remaining of localByKey.values()) merged.push(remaining);
        this.personData = merged;
      });
    } else if (response && response.error) {
      // TODO: surface an inline error to the user
      console.error('Field save error', response.error);
    } else {
      // generic refresh: if we have a selectedPerson with id, reload attributes
      if (this.selectedPerson?.id) {
        // Refresh server data but merge into existing local fields instead of replacing
        this.person.getPersonFull(this.selectedPerson.id).subscribe((fullPerson: PersonFullView) => {
          this.personFull.set(fullPerson);
          const serverAttrs = fullPerson.attributes
            ? Object.entries(fullPerson.attributes).map(([key, value]) => ({
                personId: fullPerson.personId ?? null,
                category: 'personal',
                key,
                value
              }))
            : [];

          const merged: PersonAttributeDto[] = [];
          const localByKey = new Map(this.personData.map(f => [f.key, f]));
          for (const sa of serverAttrs) {
            const existing = localByKey.get(sa.key);
            if (existing) {
              existing.value = sa.value;
              existing.personId = sa.personId;
              merged.push(existing);
              localByKey.delete(sa.key);
            } else {
              merged.push(sa);
            }
          }
          for (const remaining of localByKey.values()) merged.push(remaining);
          this.personData = merged;
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

  onNameBlur() {
    // Save name as a person attribute. If no selectedPerson.id, backend should create a person and return personId.
    const nameValue = this.personName?.trim();
    if (!nameValue) return;
    const nameAttr: PersonAttributeDto = { personId: this.selectedPerson?.id ?? null, category: 'personal', key: 'name', value: nameValue };
    this.person.addPersonData(nameAttr).subscribe({
      next: (res) => this.onFieldSaved(res, nameAttr),
      error: (err) => console.error('Failed saving name', err)
    });
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
