import { Component } from '@angular/core';
import { CommonModule } from '@angular/common';
import { MatCardModule } from '@angular/material/card';

@Component({
  selector: 'app-events-list',
  standalone: true,
  imports: [CommonModule, MatCardModule],
  template: `
    <div class="container">
      <h1>Events</h1>
      <mat-card>
        <mat-card-content>
          <p>Events timeline coming soon...</p>
        </mat-card-content>
      </mat-card>
    </div>
  `,
  styles: [`.container { max-width: 1400px; margin: 0 auto; }`]
})
export class EventsListComponent {}
