import { Component, HostListener, OnInit, ViewChild } from '@angular/core';
import { NgSelectComponent, NgSelectModule } from '@ng-select/ng-select';
import { catchError, concat, distinctUntilChanged, Observable, of, Subject, switchMap, tap } from 'rxjs';
import { PersonData, PersonService, SearchResult, SearchService } from '../client';
import { FormControl, FormsModule, ReactiveFormsModule } from '@angular/forms';
import { AsyncPipe, NgFor } from '@angular/common';
import { ActivatedRoute, Router } from '@angular/router';
import { FieldComponent } from '../field/field.component';
import { MatAutocompleteModule } from '@angular/material/autocomplete';
import { MatInputModule } from '@angular/material/input';
import { MatButtonModule } from '@angular/material/button';


@Component({
  selector: 'app-editor',
  templateUrl: './editor.component.html',
  standalone: true,
  host: { ngSkipHydration: "true" },
  imports: [FormsModule, NgSelectModule, AsyncPipe, FieldComponent, NgFor,
    ReactiveFormsModule, MatAutocompleteModule, MatInputModule,
    MatButtonModule
  ],
  styleUrls: ['./editor.component.scss']
})
export class EditorComponent implements OnInit {

  people$: Observable<SearchResult[]> = of([]);
  peopleLoading = false;
  peopleInput$ = new Subject<string>();
  selectedPerson: SearchResult | null = null;
  personData: PersonData[] = [];
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
      person.getPersonData(id).subscribe(person => {
        this.personData = person
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
    this.personData.push({ name: this.selectedPerson?.name, key: newFieldName, value: '', birthday: '0001-01-01', birthPlace: '', category: 'personal' });
    this.newFieldControl.setValue('');
  }

  selected(event: FocusEvent) {
    console.log("selected", event);
  }

  change(event: FocusEvent) {
    console.log("change", event);
    console.log("selectedPerson", this.selectedPerson);
    this.personData = [];
    if (!this.selectedPerson?.id) {
      // create person
      this.personData.push({ name: this.selectedPerson?.name, key: 'name', value: this.selectedPerson?.name, birthday: '0001-01-01', birthPlace: '', category: 'personal' });
      return;
    }
    this.person.getPersonData(this.selectedPerson.id).subscribe(person => {
      this.personData = person
    });
  }

  private loadPeople() {
    this.people$ = concat(
      of([]), // default items
      this.peopleInput$.pipe(
        distinctUntilChanged(),
        tap(() => this.peopleLoading = true),
        switchMap(term => this.searchService.serach(term).pipe(
          catchError(() => of([])), // empty list on error
          tap(() => this.peopleLoading = false)
        ))
      )
    );
  }
}
