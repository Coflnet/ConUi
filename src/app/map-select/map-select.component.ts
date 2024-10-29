import { Component, OnInit, Inject, PLATFORM_ID } from '@angular/core';
import { isPlatformBrowser } from '@angular/common';
import * as L from 'leaflet';

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
    this.map = L.map('map').setView([49.1124747, 12.6696695], 9);

    // Set up the tile layer from OpenStreetMap
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 20,
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
    }).addTo(this.map);
    
    // add option to select area
    this.map.on('click', (e) => {
      L.marker(e.latlng)
        .addTo(this.map!)
        .bindPopup('You clicked the map at ' + e.latlng.toString())
        .openPopup();
    });
  }
}
