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
  selector: 'app-events-list',
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
  templateUrl: './events-list.component.html',
  styleUrls: ['./events-list.component.scss']
})
export class EventsListComponent implements OnInit {
  displayedColumns: string[] = ['name', 'type', 'date', 'location', 'description', 'actions'];
  events = signal<SearchResult[]>([]);
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
            entityTypes: ['event'] as any,
            page: this.pageIndex,
            pageSize: this.pageSize,
            includeFacets: false
          }).pipe(
            catchError(() => of({ results: [], totalCount: 0, page: 0, pageSize: this.pageSize, totalPages: 0 }))
          );
        })
      ).subscribe(result => {
        this.events.set(result.results ?? []);
        this.totalCount.set(result.totalCount ?? 0);
        this.loading.set(false);
      });

      this.events.set([]);
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

  deleteEvent(event: SearchResult) {
    console.log('Delete event:', event);
    // TODO: Implement delete functionality
  }

  viewEvent(event: SearchResult) {
    this.router.navigate(['/events', event.id]);
  }

  getEventType(event: SearchResult): string {
    return (event as any).type || 'Event';
  }

  getEventDate(event: SearchResult): string {
    const data = (event as any).data;
    if (!data) return '-';
    if (data.date) {
      return new Date(data.date).toLocaleDateString();
    }
    if (data.startDate) {
      const start = new Date(data.startDate).toLocaleDateString();
      if (data.endDate) {
        const end = new Date(data.endDate).toLocaleDateString();
        return `${start} - ${end}`;
      }
      return start;
    }
    return '-';
  }

  getEventLocation(event: SearchResult): string {
    const data = (event as any).data;
    if (!data) return '-';
    return data.location || '-';
  }
}
