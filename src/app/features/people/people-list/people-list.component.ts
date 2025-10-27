import { Component, OnInit, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { RouterLink } from '@angular/router';
import { MatTableModule } from '@angular/material/table';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatInputModule } from '@angular/material/input';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatCardModule } from '@angular/material/card';
import { MatPaginatorModule, PageEvent } from '@angular/material/paginator';
import { FormsModule } from '@angular/forms';
import { SearchService, SearchResult } from '../../../client';
import { AuthService } from '../../../AuthService';
import { debounceTime, Subject, switchMap, catchError, of } from 'rxjs';

@Component({
  selector: 'app-people-list',
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
    MatPaginatorModule
  ],
  templateUrl: './people-list.component.html',
  styleUrls: ['./people-list.component.scss']
})
export class PeopleListComponent implements OnInit {
  displayedColumns: string[] = ['name', 'description', 'actions'];
  people = signal<SearchResult[]>([]);
  loading = signal(false);
  searchTerm = '';
  get isSearchEmpty(): boolean { return !(this.searchTerm && this.searchTerm.trim().length > 0); }
  private searchSubject = new Subject<string>();
  
  // Pagination
  totalCount = signal(0);
  pageSize = 20;
  pageIndex = 0;

  constructor(private searchService: SearchService, private authService: AuthService) {}

  ngOnInit() {
    // Defer initialization until token is available to avoid 401s
  const token = this.authService.getAccessToken();
    const initialize = () => {
      // Setup debounced search
      this.searchSubject.pipe(
        debounceTime(300),
        switchMap(term => {
          const q = (term ?? '').trim();
          if (!q) {
            // backend requires a non-empty query; return empty page locally
            return of({ results: [], totalCount: 0, page: 0, pageSize: this.pageSize, totalPages: 0 });
          }
          this.loading.set(true);
          return this.searchService.searchAdvanced({
            query: q,
            entityTypes: ['person'] as any,
            page: this.pageIndex,
            pageSize: this.pageSize,
            includeFacets: false
          }).pipe(
            catchError(() => of({ results: [], totalCount: 0, page: 0, pageSize: this.pageSize, totalPages: 0 }))
          );
        })
      ).subscribe(result => {
        this.people.set(result.results ?? []);
        this.totalCount.set(result.totalCount ?? 0);
        this.loading.set(false);
      });

      // Initial load - do not call backend without a query (backend requires query)
      this.people.set([]);
    };

    if (token) {
      initialize();
    } else {
      // wait for auth service to report logged in, or fallback after 3s
      const sub = this.authService.isLoggedIn.subscribe((loggedIn: boolean) => {
        if (loggedIn) {
          initialize();
          sub.unsubscribe();
        }
      });
      setTimeout(() => {
        // If still not initialized, initialize anyway (to avoid blocking UI permanently)
        initialize();
        try { sub.unsubscribe(); } catch {}
      }, 3000);
    }
  }

  onSearchChange(term: string) {
    this.searchTerm = term;
    this.pageIndex = 0; // Reset to first page on new search
    this.searchSubject.next(term);
  }

  onPageChange(event: PageEvent) {
    this.pageIndex = event.pageIndex;
    this.pageSize = event.pageSize;
    // only request page change if there is an active query
    if ((this.searchTerm ?? '').trim()) {
      this.searchSubject.next(this.searchTerm);
    }
  }

  private loadPeople() {
    // do nothing — we do not call search without a user-provided query
    this.people.set([]);
  }

  deletePerson(person: SearchResult) {
    // TODO: Implement delete
    console.log('Delete person:', person);
  }
}
