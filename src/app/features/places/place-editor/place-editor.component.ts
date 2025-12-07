import { Component, OnInit, signal, HostListener } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { ActivatedRoute, Router } from '@angular/router';
import { PlaceService } from '../../../client/api/place.service';
import { PlaceDto } from '../../../client/model/placeDto';
import { Place } from '../../../client/model/place';
import { PlaceFieldComponent } from '../place-field/place-field.component';
import { MapSelectComponent } from '../../../map-select/map-select.component';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatCardModule } from '@angular/material/card';
import { MatSnackBar, MatSnackBarModule } from '@angular/material/snack-bar';

@Component({
  selector: 'app-place-editor',
  templateUrl: './place-editor.component.html',
  styleUrls: ['./place-editor.component.scss'],
  standalone: true,
  imports: [
    CommonModule, FormsModule, PlaceFieldComponent, MapSelectComponent,
    MatFormFieldModule, MatInputModule, MatButtonModule, MatIconModule,
    MatCardModule, MatSnackBarModule
  ]
})
export class PlaceEditorComponent implements OnInit {
  place: Place | null = null;
  name = '';
  placeId: string | null = null;
  
  // UI state
  isCreating = signal(false);
  showMapHint = signal(true);
  pendingLocation = signal<{ lat: number; lng: number; address?: string } | null>(null);

  constructor(
    private placeService: PlaceService,
    private route: ActivatedRoute,
    private router: Router,
    private snackBar: MatSnackBar
  ) {}

  @HostListener('window:keydown', ['$event'])
  handleKeyboard(event: KeyboardEvent) {
    if (event.key === 'Escape') {
      this.cancelPending();
    }
  }

  ngOnInit(): void {
    const id = this.route.snapshot.params['id'];
    if (id) {
      this.loadPlace(id);
    }
  }

  loadPlace(id: string) {
    this.placeService.getPlace(id).subscribe({
      next: (p) => {
        this.place = p;
        this.placeId = p.id ?? null;
        this.name = p.name ?? '';
        this.showMapHint.set(false);
      },
      error: (e) => console.error(e)
    });
  }

  onMapLocationSelected(evt: { lat: number; lng: number; address?: string }) {
    // Store pending location - will create when name is confirmed
    this.pendingLocation.set(evt);
    
    // Pre-fill name from address if empty
    if (!this.name && evt.address) {
      this.name = evt.address;
    }
    
    this.showMapHint.set(false);
  }

  confirmAndCreate() {
    const loc = this.pendingLocation();
    if (!loc) return;

    this.isCreating.set(true);
    const dto: PlaceDto = {
      name: this.name || 'Neuer Ort',
      latitude: loc.lat,
      longitude: loc.lng
    };

    this.placeService.createPlace(dto).subscribe({
      next: (created) => {
        this.isCreating.set(false);
        this.pendingLocation.set(null);
        const newId = created?.id ?? null;
        if (newId) {
          this.snackBar.open('Ort erstellt!', '', { duration: 2000, panelClass: 'success-snackbar' });
          this.router.navigate(['/places', newId]);
        }
      },
      error: (err) => {
        this.isCreating.set(false);
        console.error('createPlace error', err);
        this.snackBar.open('Fehler beim Erstellen', '', { duration: 3000, panelClass: 'error-snackbar' });
      }
    });
  }

  cancelPending() {
    this.pendingLocation.set(null);
    this.showMapHint.set(true);
  }

  saveName() {
    if (!this.placeId) return;
    
    const dto: PlaceDto = { id: this.placeId, name: this.name };
    this.placeService.createPlace(dto).subscribe({
      next: (p) => {
        this.place = p;
        this.placeId = p?.id ?? this.placeId;
        this.snackBar.open('Name gespeichert', '', { duration: 2000 });
      },
      error: (e) => console.error(e)
    });
  }

  onPlaceFieldSaved(res: any) {
    if (this.placeId && res && !res.error) {
      this.snackBar.open('Gespeichert', '', { duration: 1500 });
    }
  }
}
