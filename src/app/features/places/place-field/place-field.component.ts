import { Component, ElementRef, EventEmitter, Input, Output, ViewChild } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { CommonModule } from '@angular/common';
import { PlaceData } from '../../../client/model/placeData';
import { PlaceService } from '../../../client/api/place.service';

@Component({
  selector: 'app-place-field',
  standalone: true,
  imports: [CommonModule, FormsModule, MatFormFieldModule, MatInputModule],
  templateUrl: './place-field.component.html',
  styleUrls: ['./place-field.component.scss']
})
export class PlaceFieldComponent {
  @Input()
  field: PlaceData = { placeId: null, category: '', key: '', value: '' } as any;
  @Output() saved = new EventEmitter<any>();
  @ViewChild('input', { static: false }) input: ElementRef<HTMLInputElement> | null = null;
  constructor(private placeService: PlaceService) {}

  blurred() {
    const val = this.field?.value ?? '';
    if (!val || val.toString().trim().length === 0) return;
    (this.field as any)._saving = true;
    this.placeService.addPlaceData(this.field.placeId ?? '', this.field as any).subscribe({ next: (res) => { (this.field as any)._saving = false; this.saved.emit(res); }, error: (err) => { (this.field as any)._saving = false; this.saved.emit({ error: err }); } });
  }
}
