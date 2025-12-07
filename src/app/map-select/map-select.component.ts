import { Component, Output, EventEmitter, signal, Input } from '@angular/core';
import { CommonModule } from '@angular/common';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';

/**
 * Map component for selecting a location. Click/tap to place a marker,
 * then confirm selection. Works on desktop and mobile.
 */
@Component({
    selector: 'app-map-select',
    imports: [CommonModule, MatButtonModule, MatIconModule, MatProgressSpinnerModule],
    templateUrl: './map-select.component.html',
    styleUrl: './map-select.component.scss'
})
export class MapSelectComponent {
  private map: any | undefined;
  private currentMarker: any = null;
  private L: any = null;

  @Input() height = '400px';
  @Output() locationSelected = new EventEmitter<{ lat: number, lng: number, address?: string }>();
  @Output() cancelled = new EventEmitter<void>();

  // UI state
  selectedLocation = signal<{ lat: number, lng: number, address?: string } | null>(null);
  isLoadingAddress = signal(false);
  isFullscreen = signal(false);

  ngAfterViewInit(): void {
    this.initMap();
  }

  private initMap(): void {
    (async () => {
      try {
        this.L = await import('leaflet');
        const L = this.L;
        
        // Restore saved position or default to Germany
        const mapCenter = JSON.parse(localStorage.getItem('mapCenter') || 'null') ?? [49.1124747, 12.6696695];
        const mapZoom = JSON.parse(localStorage.getItem('mapZoom') || 'null') ?? 9;
        this.map = L.map('map').setView(mapCenter, mapZoom);

        L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
          maxZoom: 19,
          attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
        }).addTo(this.map);

        // Click handler
        this.map.on('click', (e: any) => this.handleMapClick(e));

        // Persist map position
        this.map.on('moveend', () => {
          localStorage.setItem('mapCenter', JSON.stringify(this.map!.getCenter()));
        });
        this.map.on('zoomend', () => {
          localStorage.setItem('mapZoom', JSON.stringify(this.map!.getZoom()));
        });
      } catch (err) {
        console.warn('Leaflet failed to load', err);
      }
    })();
  }

  private handleMapClick(e: any): void {
    const L = this.L;
    
    // Remove previous marker
    if (this.currentMarker) {
      this.currentMarker.remove();
    }

    // Create new marker
    this.currentMarker = L.marker(e.latlng, {
      icon: L.icon({
        ...(L.Icon.Default.prototype.options || {}),
        iconUrl: 'assets/marker-icon.png',
        iconRetinaUrl: 'assets/marker-icon-2x.png',
        shadowUrl: 'assets/marker-shadow.png'
      })
    }).addTo(this.map!);

    // Set initial state
    this.selectedLocation.set({ lat: e.latlng.lat, lng: e.latlng.lng });
    this.isLoadingAddress.set(true);

    // Fetch address
    this.fetchAddress(e.latlng.lat, e.latlng.lng);
  }

  private fetchAddress(lat: number, lng: number): void {
    fetch(`https://nominatim.openstreetmap.org/reverse?format=json&lat=${lat}&lon=${lng}&zoom=18&addressdetails=1`)
      .then(res => res.json())
      .then(data => {
        const addr = data.address;
        let addressStr = '';
        if (addr.road) {
          addressStr = addr.road + (addr.house_number ? ' ' + addr.house_number : '');
        }
        if (addr.city || addr.town || addr.village) {
          addressStr += addressStr ? ', ' : '';
          addressStr += addr.city || addr.town || addr.village;
        }
        this.selectedLocation.update(loc => loc ? { ...loc, address: addressStr || data.display_name } : null);
      })
      .catch(() => {
        this.selectedLocation.update(loc => loc ? { ...loc, address: 'Adresse nicht gefunden' } : null);
      })
      .finally(() => {
        this.isLoadingAddress.set(false);
      });
  }

  confirmSelection(): void {
    const loc = this.selectedLocation();
    if (loc) {
      this.locationSelected.emit(loc);
      this.clearSelection();
    }
  }

  clearSelection(): void {
    if (this.currentMarker) {
      this.currentMarker.remove();
      this.currentMarker = null;
    }
    this.selectedLocation.set(null);
  }

  cancel(): void {
    this.clearSelection();
    this.cancelled.emit();
  }

  toggleFullscreen(): void {
    this.isFullscreen.update(v => !v);
    // Invalidate map size after transition
    setTimeout(() => {
      this.map?.invalidateSize();
    }, 300);
  }

  useCurrentLocation(): void {
    if (!navigator.geolocation) return;
    
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        const { latitude, longitude } = pos.coords;
        this.map?.setView([latitude, longitude], 15);
        // Simulate a click at current location
        this.handleMapClick({ latlng: { lat: latitude, lng: longitude } });
      },
      (err) => console.warn('Geolocation error:', err),
      { enableHighAccuracy: true }
    );
  }
}
