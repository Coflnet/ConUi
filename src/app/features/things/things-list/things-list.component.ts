import { Component } from '@angular/core';
import { CommonModule } from '@angular/common';
import { MatCardModule } from '@angular/material/card';

@Component({
  selector: 'app-things-list',
  standalone: true,
  imports: [CommonModule, MatCardModule],
  template: `
    <div class="container">
      <h1>Things</h1>
      <mat-card>
        <mat-card-content>
          <p>Things management coming soon...</p>
        </mat-card-content>
      </mat-card>
    </div>
  `,
  styles: [`.container { max-width: 1400px; margin: 0 auto; }`]
})
export class ThingsListComponent {}
