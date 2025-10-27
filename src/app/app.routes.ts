import { Routes } from '@angular/router';
import { LoginComponent } from './login/login.component';
import { EditorComponent } from './editor/editor.component';
import { ShellComponent } from './layout/shell/shell.component';

export const routes: Routes = [
    { path: 'login', component: LoginComponent },
    {
        path: '',
        component: ShellComponent,
        children: [
            { path: 'dashboard', loadComponent: () => import('./features/dashboard/dashboard.component').then(m => m.DashboardComponent) },
            { path: 'people', loadComponent: () => import('./features/people/people-list/people-list.component').then(m => m.PeopleListComponent) },
            { path: 'people/new', component: EditorComponent },
            { path: 'people/:id', component: EditorComponent },
            { path: 'people/:id/edit', component: EditorComponent },
            { path: 'places', loadComponent: () => import('./features/places/places-list/places-list.component').then(m => m.PlacesListComponent) },
            { path: 'places/new', loadComponent: () => import('./features/places/place-editor/place-editor.component').then(m => m.PlaceEditorComponent) },
            { path: 'places/:id', loadComponent: () => import('./features/places/place-editor/place-editor.component').then(m => m.PlaceEditorComponent) },
            { path: 'places/:id/edit', loadComponent: () => import('./features/places/place-editor/place-editor.component').then(m => m.PlaceEditorComponent) },
            { path: 'events', loadComponent: () => import('./features/events/events-list/events-list.component').then(m => m.EventsListComponent) },
            { path: 'events/new', component: EditorComponent },
            { path: 'events/:id', component: EditorComponent },
            { path: 'events/:id/edit', component: EditorComponent },
            { path: 'things', loadComponent: () => import('./features/things/things-list/things-list.component').then(m => m.ThingsListComponent) },
            { path: 'things/new', component: EditorComponent },
            { path: 'things/:id', component: EditorComponent },
            { path: 'things/:id/edit', component: EditorComponent },
            { path: 'timeline', loadComponent: () => import('./features/timeline/timeline.component').then(m => m.TimelineComponent) },
            { path: 'relationships', loadComponent: () => import('./features/relationships/relationships.component').then(m => m.RelationshipsComponent) },
            { path: 'relationships/new', component: EditorComponent },
            { path: 'relationships/:id', component: EditorComponent },
            { path: 'relationships/:id/edit', component: EditorComponent },
            { path: 'share', loadComponent: () => import('./features/share/share.component').then(m => m.ShareComponent) },
            { path: 'editor', component: EditorComponent },
            { path: 'map', loadComponent: () => import('./map-container/map-container.component').then(m => m.MapContainerComponent) },
            { path: 'edit/p/:person', component: EditorComponent },
            { path: '', redirectTo: '/dashboard', pathMatch: 'full' }
        ]
    }
];

