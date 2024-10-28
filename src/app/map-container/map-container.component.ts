import { Component } from '@angular/core';
import { MapSelectComponent } from '../map-select/map-select.component';

@Component({
  selector: 'app-map-container',
  standalone: true,
  imports: [MapSelectComponent],
  templateUrl: './map-container.component.html',
  styleUrl: './map-container.component.scss'
})
export class MapContainerComponent {

}
