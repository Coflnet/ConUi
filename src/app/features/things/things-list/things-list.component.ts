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
  selector: 'app-things-list',
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
  templateUrl: './things-list.component.html',
  styleUrls: ['./things-list.component.scss']
})
export class ThingsListComponent implements OnInit {
  displayedColumns: string[] = ['name', 'type', 'owner', 'description', 'actions'];
  things = signal<SearchResult[]>([]);
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
            entityTypes: ['thing'] as any,
            page: this.pageIndex,
            pageSize: this.pageSize,
            includeFacets: false
          }).pipe(
            catchError(() => of({ results: [], totalCount: 0, page: 0, pageSize: this.pageSize, totalPages: 0 }))
          );
        })
      ).subscribe(result => {
        this.things.set(result.results ?? []);
        this.totalCount.set(result.totalCount ?? 0);
        this.loading.set(false);
      });

      this.things.set([]);
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

  deleteThing(thing: SearchResult) {
    console.log('Delete thing:', thing);
    // TODO: Implement delete functionality
  }

  viewThing(thing: SearchResult) {
    this.router.navigate(['/things', thing.id]);
  }

  getThingType(thing: SearchResult): string {
    return (thing as any).type || 'Thing';
  }

  getOwner(thing: SearchResult): string {
    const data = (thing as any).data;
    if (!data) return '-';
    return data.owner || '-';
  }

  getThingIcon(thing: SearchResult): string {
    const type = this.getThingType(thing).toLowerCase();
    
    // Map thing types to relevant Material icons
    if (type.includes('book')) return 'menu_book';
    if (type.includes('photo')) return 'photo';
    if (type.includes('document')) return 'description';
    if (type.includes('jewelry') || type.includes('jewellery')) return 'diamond';
    if (type.includes('furniture')) return 'chair';
    if (type.includes('vehicle') || type.includes('car')) return 'directions_car';
    if (type.includes('tool')) return 'build';
    if (type.includes('art')) return 'palette';
    if (type.includes('clothing') || type.includes('apparel')) return 'checkroom';
    if (type.includes('electronic')) return 'devices';
    if (type.includes('heirloom')) return 'stars';
    
    // Default icon for generic things
    return 'inventory_2';
  }
}
