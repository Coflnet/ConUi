import { Component, OnInit, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { Router, RouterLink } from '@angular/router';
import { MatTableModule } from '@angular/material/table';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatInputModule } from '@angular/material/input';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatCardModule } from '@angular/material/card';
import { MatPaginatorModule, PageEvent } from '@angular/material/paginator';
import { MatTooltipModule } from '@angular/material/tooltip';
import { FormsModule } from '@angular/forms';
import { SearchService, SearchResult } from '../../../client';
import { AuthService } from '../../../AuthService';
import { debounceTime, Subject, switchMap, catchError, of } from 'rxjs';

@Component({
  selector: 'app-places-list',
  standalone: true,
  imports: [
    CommonModule,
    RouterLink,
    FormsModule,
    MatTableModule,
    MatButtonModule,
    MatIconModule,
    MatInputModule,
    MatFormFieldModule,
    MatCardModule,
    MatPaginatorModule,
    MatTooltipModule
  ],
  templateUrl: './places-list.component.html',
  styleUrls: ['./places-list.component.scss']
})
export class PlacesListComponent implements OnInit {
  displayedColumns: string[] = ['name', 'type', 'location', 'description', 'actions'];
  places = signal<SearchResult[]>([]);
  loading = signal(false);
  searchTerm = '';
  get isSearchEmpty(): boolean { return !(this.searchTerm && this.searchTerm.trim().length > 0); }
  private searchSubject = new Subject<string>();
  
  // Pagination
  totalCount = signal(0);
  pageSize = 20;
  pageIndex = 0;

  constructor(
    private searchService: SearchService, 
    private authService: AuthService,
    private router: Router
  ) {}

  ngOnInit() {
    const token = this.authService.getAccessToken();
    const initialize = () => {
      this.searchSubject.pipe(
        debounceTime(300),
        switchMap(term => {
          const q = (term ?? '').trim();
          if (!q) {
            return of({ results: [], totalCount: 0, page: 0, pageSize: this.pageSize, totalPages: 0 });
          }
          this.loading.set(true);
          return this.searchService.searchAdvanced({
            query: q,
            entityTypes: ['place'] as any,
            page: this.pageIndex,
            pageSize: this.pageSize,
            includeFacets: false
          }).pipe(
            catchError(() => of({ results: [], totalCount: 0, page: 0, pageSize: this.pageSize, totalPages: 0 }))
          );
        })
      ).subscribe(result => {
        this.places.set(result.results ?? []);
        this.totalCount.set(result.totalCount ?? 0);
        this.loading.set(false);
      });

      this.places.set([]);
    };

    if (token) {
      initialize();
    } else {
      const sub = this.authService.isLoggedIn.subscribe((loggedIn: boolean) => {
        if (loggedIn) {
          initialize();
          sub.unsubscribe();
        }
      });
      setTimeout(() => {
        initialize();
        try { sub.unsubscribe(); } catch {}
      }, 3000);
    }
  }

  onSearchChange(term: string) {
    this.searchTerm = term;
    this.pageIndex = 0;
    this.searchSubject.next(term);
  }

  onPageChange(event: PageEvent) {
    this.pageIndex = event.pageIndex;
    this.pageSize = event.pageSize;
    if ((this.searchTerm ?? '').trim()) {
      this.searchSubject.next(this.searchTerm);
    }
  }

  deletePlace(place: SearchResult) {
    console.log('Delete place:', place);
    // TODO: Implement delete functionality
  }

  viewPlace(place: SearchResult) {
    this.router.navigate(['/places', place.id]);
  }

  getPlaceType(place: SearchResult): string {
    return (place as any).type || 'Place';
  }

  getLocation(place: SearchResult): string {
    const data = (place as any).data;
    if (!data) return '';
    const parts = [];
    if (data.city) parts.push(data.city);
    if (data.country) parts.push(data.country);
    if (data.latitude && data.longitude) {
      parts.push(`${data.latitude.toFixed(4)}, ${data.longitude.toFixed(4)}`);
    }
    return parts.join(', ') || '-';
  }
}
