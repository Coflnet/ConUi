import { Component, OnInit, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { RouterLink } from '@angular/router';
import { MatTableModule } from '@angular/material/table';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatInputModule } from '@angular/material/input';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatCardModule } from '@angular/material/card';
import { FormsModule } from '@angular/forms';
import { SearchService, SearchResult } from '../../../client';
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
    MatCardModule
  ],
  templateUrl: './people-list.component.html',
  styleUrls: ['./people-list.component.scss']
})
export class PeopleListComponent implements OnInit {
  displayedColumns: string[] = ['name', 'description', 'actions'];
  people = signal<SearchResult[]>([]);
  loading = signal(false);
  searchTerm = '';
  private searchSubject = new Subject<string>();

  constructor(private searchService: SearchService) {}

  ngOnInit() {
    // Setup debounced search
    this.searchSubject.pipe(
      debounceTime(300),
      switchMap(term => {
        if (!term || term.length < 2) {
          return of([]);
        }
        this.loading.set(true);
        return this.searchService.search(term).pipe(
          catchError(() => of([]))
        );
      })
    ).subscribe(results => {
      this.people.set(results.filter(r => r.type === 'person' || !r.type));
      this.loading.set(false);
    });

    // Initial load - get all people
    this.loadPeople();
  }

  onSearchChange(term: string) {
    this.searchTerm = term;
    this.searchSubject.next(term);
  }

  private loadPeople() {
    this.loading.set(true);
    this.searchService.search('').pipe(
      catchError(() => of([]))
    ).subscribe(results => {
      this.people.set(results.filter(r => r.type === 'person' || !r.type));
      this.loading.set(false);
    });
  }

  deletePerson(person: SearchResult) {
    // TODO: Implement delete
    console.log('Delete person:', person);
  }
}
