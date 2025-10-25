import { Component, signal } from '@angular/core';
import { RouterLink, RouterOutlet } from '@angular/router';
import { MatSidenavModule } from '@angular/material/sidenav';
import { MatToolbarModule } from '@angular/material/toolbar';
import { MatListModule } from '@angular/material/list';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { CommonModule } from '@angular/common';

interface NavItem {
  label: string;
  route: string;
  icon: string;
}

@Component({
  selector: 'app-shell',
  standalone: true,
  imports: [
    CommonModule,
    RouterOutlet,
    RouterLink,
    MatSidenavModule,
    MatToolbarModule,
    MatListModule,
    MatIconModule,
    MatButtonModule
  ],
  templateUrl: './shell.component.html',
  styleUrls: ['./shell.component.scss']
})
export class ShellComponent {
  sidenavOpened = signal(true);
  
  navItems: NavItem[] = [
    { label: 'Dashboard', route: '/dashboard', icon: 'dashboard' },
    { label: 'People', route: '/people', icon: 'people' },
    { label: 'Places', route: '/places', icon: 'place' },
    { label: 'Events', route: '/events', icon: 'event' },
    { label: 'Things', route: '/things', icon: 'category' },
    { label: 'Timeline', route: '/timeline', icon: 'timeline' },
    { label: 'Relationships', route: '/relationships', icon: 'hub' },
    { label: 'Share', route: '/share', icon: 'share' },
  ];

  toggleSidenav() {
    this.sidenavOpened.update(value => !value);
  }
}
