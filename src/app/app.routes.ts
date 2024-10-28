import { Routes } from '@angular/router';
import { LoginComponent } from './login/login.component';
import { EditorComponent } from './editor/editor.component';

export const routes: Routes = [
    { path: 'login', component: LoginComponent },
    { path: 'editor', component: EditorComponent },
    { path: 'map', loadComponent: () => import('./map-container/map-container.component').then(m => m.MapContainerComponent) },
    { path: 'edit/p/:person', component: EditorComponent },
    { path: '', redirectTo: '/editor', pathMatch: 'full' }
];
