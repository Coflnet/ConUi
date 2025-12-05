import { Component, OnInit, signal, HostListener } from '@angular/core';
import { CommonModule } from '@angular/common';
import { ActivatedRoute, Router, RouterModule } from '@angular/router';
import { FormsModule } from '@angular/forms';
import { MatCardModule } from '@angular/material/card';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatSelectModule } from '@angular/material/select';
import { MatDatepickerModule } from '@angular/material/datepicker';
import { MatNativeDateModule } from '@angular/material/core';
import { MatSliderModule } from '@angular/material/slider';
import { MatAutocompleteModule } from '@angular/material/autocomplete';
import { MatSnackBar, MatSnackBarModule } from '@angular/material/snack-bar';
import { MatChipsModule } from '@angular/material/chips';
import { MatTooltipModule } from '@angular/material/tooltip';
import { NgSelectModule } from '@ng-select/ng-select';
import { Subject } from 'rxjs';
import { debounceTime, distinctUntilChanged, switchMap } from 'rxjs/operators';
import { RelationshipService } from '../../../client/api/relationship.service';
import { PersonService } from '../../../client/api/person.service';
import { SearchService } from '../../../client/api/search.service';
import { RelationshipDto, EntityType, Relationship } from '../../../client/model/models';

@Component({
  selector: 'app-relationship-editor',
  standalone: true,
  imports: [
    CommonModule,
    RouterModule,
    FormsModule,
    MatCardModule,
    MatFormFieldModule,
    MatInputModule,
    MatButtonModule,
    MatIconModule,
    MatSelectModule,
    MatDatepickerModule,
    MatNativeDateModule,
    MatSliderModule,
    MatAutocompleteModule,
    MatSnackBarModule,
    MatChipsModule,
    MatTooltipModule,
    NgSelectModule
  ],
  templateUrl: './relationship-editor.component.html',
  styleUrl: './relationship-editor.component.scss'
})
export class RelationshipEditorComponent implements OnInit {
  relationshipId: string | null = null;
  relationship = signal<Relationship | null>(null);
  loading = signal(false);
  saving = signal(false);

  // Form fields
  fromPersonId: string | null = null;
  toPersonId: string | null = null;
  relationshipType = '';
  startDate: Date | null = null;
  endDate: Date | null = null;
  certainty = 100;
  notes = '';

  // UI state
  showValidation = signal(false);
  successMessage = signal<string | null>(null);
  errorMessage = signal<string | null>(null);

  // Quick type buttons for common relationships
  quickTypes = [
    { value: 'Ehepartner', icon: 'favorite', label: 'Ehepartner' },
    { value: 'Elternteil', icon: 'family_restroom', label: 'Elternteil' },
    { value: 'Kind', icon: 'child_care', label: 'Kind' },
    { value: 'Geschwister', icon: 'people', label: 'Geschwister' },
    { value: 'Freund', icon: 'person', label: 'Freund' },
  ];

  // Person search
  peopleSearch$ = signal<any[]>([]);
  fromPersonSearch$ = new Subject<string>();
  toPersonSearch$ = new Subject<string>();
  fromPersonResults$ = signal<any[]>([]);
  toPersonResults$ = signal<any[]>([]);
  loadingFromPerson = signal(false);
  loadingToPerson = signal(false);

  // Function to create a new person when added via ng-select
  addPersonTag = (name: string) => {
    return { id: `new_${Date.now()}`, name: name, _isNew: true };
  };

  // Predefined relationship types (common German and English types)
  relationshipTypes = [
    // Family
    { value: 'Vater', label: 'Vater (Father)' },
    { value: 'Mutter', label: 'Mutter (Mother)' },
    { value: 'Sohn', label: 'Sohn (Son)' },
    { value: 'Tochter', label: 'Tochter (Daughter)' },
    { value: 'Bruder', label: 'Bruder (Brother)' },
    { value: 'Schwester', label: 'Schwester (Sister)' },
    { value: 'Großvater', label: 'Großvater (Grandfather)' },
    { value: 'Großmutter', label: 'Großmutter (Grandmother)' },
    { value: 'Enkel', label: 'Enkel (Grandson)' },
    { value: 'Enkelin', label: 'Enkelin (Granddaughter)' },
    { value: 'Onkel', label: 'Onkel (Uncle)' },
    { value: 'Tante', label: 'Tante (Aunt)' },
    { value: 'Neffe', label: 'Neffe (Nephew)' },
    { value: 'Nichte', label: 'Nichte (Niece)' },
    { value: 'Cousin', label: 'Cousin' },
    { value: 'Cousine', label: 'Cousine' },
    
    // Marital/Partnership
    { value: 'Ehemann', label: 'Ehemann (Husband)' },
    { value: 'Ehefrau', label: 'Ehefrau (Wife)' },
    { value: 'Partner', label: 'Partner' },
    { value: 'Partnerin', label: 'Partnerin' },
    { value: 'Verlobter', label: 'Verlobter (Fiancé)' },
    { value: 'Verlobte', label: 'Verlobte (Fiancée)' },
    { value: 'Ex-Partner', label: 'Ex-Partner' },
    { value: 'Ex-Partnerin', label: 'Ex-Partnerin' },
    
    // Social
    { value: 'Freund', label: 'Freund (Friend - male)' },
    { value: 'Freundin', label: 'Freundin (Friend - female)' },
    { value: 'Bekannter', label: 'Bekannter (Acquaintance)' },
    { value: 'Nachbar', label: 'Nachbar (Neighbor)' },
    { value: 'Nachbarin', label: 'Nachbarin (Neighbor - female)' },
    
    // Professional
    { value: 'Chef', label: 'Chef (Boss)' },
    { value: 'Chefin', label: 'Chefin (Boss - female)' },
    { value: 'Angestellter', label: 'Angestellter (Employee)' },
    { value: 'Kollege', label: 'Kollege (Colleague)' },
    { value: 'Kollegin', label: 'Kollegin (Colleague - female)' },
    { value: 'Mentor', label: 'Mentor' },
    { value: 'Mentorin', label: 'Mentorin (Mentor - female)' },
    { value: 'Geschäftspartner', label: 'Geschäftspartner (Business Partner)' },
    
    // Other
    { value: 'Vermieter', label: 'Vermieter (Landlord)' },
    { value: 'Vermieterin', label: 'Vermieterin (Landlord - female)' },
    { value: 'Mieter', label: 'Mieter (Tenant)' },
    { value: 'Besitzer', label: 'Besitzer (Owner)' },
    { value: 'Arzt', label: 'Arzt (Doctor)' },
    { value: 'Ärztin', label: 'Ärztin (Doctor - female)' },
    { value: 'Lehrer', label: 'Lehrer (Teacher)' },
    { value: 'Lehrerin', label: 'Lehrerin (Teacher - female)' },
    { value: 'Schüler', label: 'Schüler (Student)' },
    { value: 'Schülerin', label: 'Schülerin (Student - female)' }
  ];

  constructor(
    private route: ActivatedRoute,
    private router: Router,
    private relationshipService: RelationshipService,
    private personService: PersonService,
    private searchService: SearchService,
    private snackBar: MatSnackBar
  ) {}

  // Keyboard shortcuts
  @HostListener('document:keydown', ['$event'])
  handleKeyboardEvent(event: KeyboardEvent) {
    // Ctrl+S to save
    if (event.ctrlKey && event.key === 's') {
      event.preventDefault();
      this.save();
    }
    // Escape to cancel
    if (event.key === 'Escape') {
      this.cancel();
    }
  }

  ngOnInit(): void {
    this.relationshipId = this.route.snapshot.paramMap.get('id');
    
    // Check for query params to pre-fill form
    const fromPersonId = this.route.snapshot.queryParamMap.get('fromPersonId');
    const toPersonId = this.route.snapshot.queryParamMap.get('toPersonId');
    
    if (fromPersonId) {
      this.fromPersonId = fromPersonId;
      // Load person name for display
      this.personService.getPersonFull(fromPersonId).subscribe({
        next: (person) => {
          this.fromPersonResults$.set([{
            id: person.personId,
            name: person.name,
            type: 'Person'
          } as any]);
        }
      });
    }
    
    if (toPersonId) {
      this.toPersonId = toPersonId;
      // Load person name for display
      this.personService.getPersonFull(toPersonId).subscribe({
        next: (person) => {
          this.toPersonResults$.set([{
            id: person.personId,
            name: person.name,
            type: 'Person'
          } as any]);
        }
      });
    }
    
    if (this.relationshipId && this.relationshipId !== 'new') {
      this.loadRelationship();
    }

    // Set up typeahead for from person search
    this.fromPersonSearch$.pipe(
      debounceTime(300),
      distinctUntilChanged(),
      switchMap(term => {
        if (!term || term.length < 2) {
          this.fromPersonResults$.set([]);
          return [];
        }
        this.loadingFromPerson.set(true);
        return this.searchService.search(term);
      })
    ).subscribe({
      next: (results) => {
        const people = results?.filter((r: any) => r.type === 'Person') || [];
        this.fromPersonResults$.set(people);
        this.loadingFromPerson.set(false);
      },
      error: () => {
        this.loadingFromPerson.set(false);
      }
    });

    // Set up typeahead for to person search
    this.toPersonSearch$.pipe(
      debounceTime(300),
      distinctUntilChanged(),
      switchMap(term => {
        if (!term || term.length < 2) {
          this.toPersonResults$.set([]);
          return [];
        }
        this.loadingToPerson.set(true);
        return this.searchService.search(term);
      })
    ).subscribe({
      next: (results) => {
        const people = results?.filter((r: any) => r.type === 'Person') || [];
        this.toPersonResults$.set(people);
        this.loadingToPerson.set(false);
      },
      error: () => {
        this.loadingToPerson.set(false);
      }
    });
  }

  loadRelationship(): void {
    if (!this.relationshipId) return;
    
    this.loading.set(true);
    this.relationshipService.getRelationship(this.relationshipId).subscribe({
      next: (rel) => {
        this.relationship.set(rel);
        this.populateForm(rel);
        this.loading.set(false);
      },
      error: (err) => {
        console.error('Failed to load relationship', err);
        this.loading.set(false);
      }
    });
  }

  populateForm(rel: Relationship): void {
    this.fromPersonId = rel.fromEntityId || null;
    this.toPersonId = rel.toEntityId || null;
    this.relationshipType = rel.relationshipType || '';
    this.startDate = rel.startDate ? new Date(rel.startDate) : null;
    this.endDate = rel.endDate ? new Date(rel.endDate) : null;
    this.certainty = rel.certainty || 100;
    this.notes = rel.notes || '';
  }

  // Swap from and to persons
  swapPersons(): void {
    const tempId = this.fromPersonId;
    const tempResults = this.fromPersonResults$();
    
    this.fromPersonId = this.toPersonId;
    this.fromPersonResults$.set(this.toPersonResults$());
    
    this.toPersonId = tempId;
    this.toPersonResults$.set(tempResults);
    
    this.snackBar.open('Personen getauscht', '', { duration: 1500 });
  }

  // Set quick relationship type
  setQuickType(type: string): void {
    this.relationshipType = type;
  }

  // Clear error/success messages
  clearMessages(): void {
    this.errorMessage.set(null);
    this.successMessage.set(null);
  }

  // Validate form
  isFormValid(): boolean {
    return !!(this.fromPersonId && this.toPersonId && this.relationshipType);
  }

  save(): void {
    this.showValidation.set(true);
    this.clearMessages();

    if (!this.isFormValid()) {
      this.errorMessage.set('Bitte füllen Sie alle Pflichtfelder aus.');
      return;
    }

    this.saving.set(true);

    // Check if we need to create new persons
    const fromPerson = this.fromPersonResults$().find(p => p.id === this.fromPersonId);
    const toPerson = this.toPersonResults$().find(p => p.id === this.toPersonId);
    
    const createPersonPromises: Promise<any>[] = [];
    
    // Create "from" person if needed
    if (fromPerson && fromPerson._isNew) {
      createPersonPromises.push(
        new Promise((resolve, reject) => {
          this.personService.addPersonData({
            personId: null,
            category: 'personal',
            key: 'name',
            value: fromPerson.name
          }).subscribe({
            next: (result: any) => {
              this.fromPersonId = result.personId;
              resolve(result.personId);
            },
            error: reject
          });
        })
      );
    }
    
    // Create "to" person if needed
    if (toPerson && toPerson._isNew) {
      createPersonPromises.push(
        new Promise((resolve, reject) => {
          this.personService.addPersonData({
            personId: null,
            category: 'personal',
            key: 'name',
            value: toPerson.name
          }).subscribe({
            next: (result: any) => {
              this.toPersonId = result.personId;
              resolve(result.personId);
            },
            error: reject
          });
        })
      );
    }
    
    // Wait for person creation before creating relationship
    Promise.all(createPersonPromises)
      .then(() => {
        const dto: RelationshipDto = {
          id: this.relationshipId || undefined,
          fromEntityType: EntityType.Person,
          fromEntityId: this.fromPersonId!,
          toEntityType: EntityType.Person,
          toEntityId: this.toPersonId!,
          relationshipType: this.relationshipType,
          startDate: this.startDate ? this.startDate.toISOString() : null,
          endDate: this.endDate ? this.endDate.toISOString() : null,
          certainty: this.certainty,
          notes: this.notes || null
        };

        const request = this.relationshipId && this.relationshipId !== 'new'
          ? this.relationshipService.updateRelationship(this.relationshipId, dto)
          : this.relationshipService.createRelationship(dto);

        request.subscribe({
          next: () => {
            this.saving.set(false);
            this.snackBar.open(
              this.relationshipId && this.relationshipId !== 'new' 
                ? 'Beziehung aktualisiert' 
                : 'Beziehung erstellt',
              'OK',
              { duration: 3000 }
            );
            this.router.navigate(['/relationships']);
          },
          error: (err: any) => {
            console.error('Failed to save relationship', err);
            this.errorMessage.set('Fehler beim Speichern der Beziehung');
            this.saving.set(false);
          }
        });
      })
      .catch((err) => {
        console.error('Failed to create person', err);
        this.errorMessage.set('Fehler beim Erstellen der Person');
        this.saving.set(false);
      });
  }

  cancel(): void {
    this.router.navigate(['/relationships']);
  }

  // Confirmation dialog state
  showDeleteConfirm = signal(false);

  confirmDelete(): void {
    this.showDeleteConfirm.set(true);
  }

  cancelDelete(): void {
    this.showDeleteConfirm.set(false);
  }

  deleteRelationship(): void {
    if (!this.relationshipId || this.relationshipId === 'new') return;

    this.relationshipService.deleteRelationship(this.relationshipId).subscribe({
      next: () => {
        this.snackBar.open('Beziehung gelöscht', '', { duration: 2000 });
        this.router.navigate(['/relationships']);
      },
      error: (err) => {
        console.error('Failed to delete relationship', err);
        this.errorMessage.set('Fehler beim Löschen der Beziehung');
        this.showDeleteConfirm.set(false);
      }
    });
  }

  formatLabel(value: number): string {
    return `${value}%`;
  }
}
