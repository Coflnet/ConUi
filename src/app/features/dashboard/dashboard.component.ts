import { Component } from '@angular/core';
import { CommonModule } from '@angular/common';
import { MatCardModule } from '@angular/material/card';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { RouterLink } from '@angular/router';

@Component({
  selector: 'app-dashboard',
  standalone: true,
  imports: [CommonModule, MatCardModule, MatIconModule, MatButtonModule, RouterLink],
  templateUrl: './dashboard.component.html',
  styleUrls: ['./dashboard.component.scss']
})
export class DashboardComponent {
  stats = [
    { label: 'People', count: 0, icon: 'people', route: '/people', color: '#4CAF50' },
    { label: 'Places', count: 0, icon: 'place', route: '/places', color: '#2196F3' },
    { label: 'Events', count: 0, icon: 'event', route: '/events', color: '#FF9800' },
    { label: 'Things', count: 0, icon: 'category', route: '/things', color: '#9C27B0' },
  ];

  recentActivity: any[] = [];
}
