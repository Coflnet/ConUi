import { Component, OnInit, Inject, PLATFORM_ID } from '@angular/core';
import * as L from 'leaflet';

/**
 * This component only renders in the browser and initializes a map with OpenStreetMap tiles.
 */
@Component({
  selector: 'app-map-select',
  standalone: true,
  imports: [],
  templateUrl: './map-select.component.html',
  styleUrl: './map-select.component.scss'
})
export class MapSelectComponent {
  private map: L.Map | undefined;

  ngAfterViewInit(): void {
    this.initMap();
  }

  private initMap(): void {
    // Initialize the map and set its view to center of Germany
    let mapCenter = JSON.parse(localStorage.getItem('mapCenter') || 'null') ?? [49.1124747, 12.6696695];
    let mapZoom = JSON.parse(localStorage.getItem('mapZoom') || 'null') ?? 9;
    this.map = L.map('map').setView(mapCenter, mapZoom);

    // Set up the tile layer from OpenStreetMap
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19,
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
    }).addTo(this.map);
    
    // add option to select area
    this.map.on('click', (e) => {
      L.marker(e.latlng)
        .addTo(this.map!)
        .bindPopup('You clicked the map at ' + e.latlng.toString())
        .openPopup();
    });

    this.map.on('moveend', () => {
      console.log(this.map!.getCenter());
      localStorage.setItem('mapCenter', JSON.stringify(this.map!.getCenter()));
    });
    this.map.on('zoomend', () => {
      console.log(this.map!.getZoom());
      localStorage.setItem('mapZoom', JSON.stringify(this.map!.getZoom()));
    });
  }
}
