import { ApplicationConfig, provideZoneChangeDetection, APP_INITIALIZER, Inject, PLATFORM_ID } from '@angular/core';
import { provideRouter } from '@angular/router';
import { Router, NavigationStart } from '@angular/router';
import { filter } from 'rxjs/operators';
import { isPlatformBrowser } from '@angular/common';

import { routes } from './app.routes';
import { provideClientHydration } from '@angular/platform-browser';
import { provideAnimationsAsync } from '@angular/platform-browser/animations/async';

import {
  GoogleLoginProvider,
  SocialAuthServiceConfig,
} from '@abacritt/angularx-social-login';
import { provideHttpClient, withFetch, withInterceptors } from '@angular/common/http';
import { AuthStorageService, authInterceptor } from './auth.interceptor';
import { AuthService } from './AuthService';
import { Configuration } from './client';
import { environment } from '../environments/environment';
export const appConfig: ApplicationConfig = {
  providers: [provideZoneChangeDetection({ eventCoalescing: true }), provideRouter(routes), provideClientHydration(), provideAnimationsAsync(), 
    {
      provide: 'SocialAuthServiceConfig',
      useValue: {
        autoLogin: false,
        providers: [
          {
            id: GoogleLoginProvider.PROVIDER_ID,
            provider: new GoogleLoginProvider(
              '423456355818-mpv5o7fdvu70j6bqlam0audc1n31h133.apps.googleusercontent.com'
            )
          }
        ],
        onError: (error) => {
          console.error(error);
        }
      } as SocialAuthServiceConfig
    },
    provideHttpClient(withInterceptors([authInterceptor]), withFetch()),
  // Eagerly instantiate AuthService so background anonymous login runs on app start
  AuthService,
    {
      provide: Configuration,
      useFactory: (authStorage: AuthStorageService) => new Configuration(
        {
          basePath: environment.basepath,
          credentials: {
            'Bearer': () => authStorage.getToken() ?? undefined
          }
        }
      ),
      deps: [AuthStorageService],
      multi: false
    }
    ,
    // Global route guard: redirect unauthenticated users to /login except when visiting /dashboard or /login
    {
      provide: APP_INITIALIZER,
      useFactory: (router: Router, authService: AuthService, platformId: Object) => {
        return () => {
          // Only attach the navigation listener in the browser. This avoids interfering with
          // server-side prerender/route extraction which runs at build time.
          if (!isPlatformBrowser(platformId)) return;
          // When running locally (dev / E2E) don't force redirect to login so tests
          // and local development can open list pages without a real auth flow.
          try {
            const hostname = window.location.hostname;
            if (hostname === 'localhost' || hostname === '127.0.0.1') return;
          } catch (e) {
            // ignore if window is not available for some reason
          }
          router.events.pipe(filter(e => e instanceof NavigationStart)).subscribe((e: any) => {
            try {
              const url: string = e.url ?? '';
              // allow /dashboard and /login
              if (!authService.isAuthenticated() && url !== '/dashboard' && url !== '/login') {
                // redirect to login and include the original URL so we can return after authentication
                router.navigate(['/login'], { queryParams: { returnUrl: url } });
              }
            } catch (err) {
              // swallow
            }
          });
        };
      },
      deps: [Router, AuthService, PLATFORM_ID],
      multi: true
    }
  ]
};
