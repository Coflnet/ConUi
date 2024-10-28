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
    // Initialize the map and set its view
    this.map = L.map('map').setView([51.505, -0.09], 13);

    // Set up the tile layer from OpenStreetMap
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19,
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
    }).addTo(this.map);

    // Add a marker at the map center
    L.marker([51.505, -0.09])
      .addTo(this.map)
      .bindPopup('A pretty CSS3 popup.<br> Easily customizable.')
      .openPopup();
    
    // add option to select area
    this.map.on('click', (e) => {
      L.marker(e.latlng)
        .addTo(this.map!)
        .bindPopup('You clicked the map at ' + e.latlng.toString())
        .openPopup();
    });
  }
}
