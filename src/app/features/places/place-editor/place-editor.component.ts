import { Component, OnInit, ViewChild } from '@angular/core';
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

@Component({
  selector: 'app-place-editor',
  templateUrl: './place-editor.component.html',
  styleUrls: ['./place-editor.component.scss'],
  standalone: true,
  imports: [CommonModule, FormsModule, PlaceFieldComponent, MapSelectComponent, MatFormFieldModule, MatInputModule, MatButtonModule]
})
export class PlaceEditorComponent implements OnInit {
  place: Place | null = null;
  name = '';
  placeId: string | null = null;

  constructor(private placeService: PlaceService, private route: ActivatedRoute, private router: Router) {}

  ngOnInit(): void {
    const id = this.route.snapshot.params['id'];
    if (id) {
      this.loadPlace(id);
    }
  }

  loadPlace(id: string) {
    this.placeService.getPlace(id).subscribe({ next: (p) => { this.place = p; this.placeId = p.id ?? null; this.name = p.name ?? ''; }, error: (e) => console.error(e) });
  }

  onMapLocationSelected(evt: { lat: number; lng: number; address?: string }) {
    const dto: PlaceDto = { name: this.name || 'neu', latitude: evt.lat, longitude: evt.lng };
    this.placeService.createPlace(dto).subscribe({ next: (created) => {
      const newId = created?.id ?? null;
      if (newId) this.router.navigate(['/places', newId]);
    }, error: (err) => console.error('createPlace error', err)});
  }

  saveName() {
    const dto: PlaceDto = { id: this.placeId ?? undefined, name: this.name };
    this.placeService.createPlace(dto).subscribe({ next: (p) => { this.place = p; this.placeId = p?.id ?? this.placeId; }, error: (e) => console.error(e) });
  }

  onPlaceFieldSaved(res: any) {
    // placeholder handler - refresh or notify
    console.log('place field saved', res);
    if (this.placeId && res && !res.error) {
      // could reload fields via API here
    }
  }
}
