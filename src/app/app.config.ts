import { ApplicationConfig, provideZoneChangeDetection, APP_INITIALIZER } from '@angular/core';
import { provideRouter } from '@angular/router';
import { Router, NavigationStart } from '@angular/router';
import { filter } from 'rxjs/operators';

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
      useFactory: (router: Router, authService: AuthService) => {
        return () => {
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
      deps: [Router, AuthService],
      multi: true
    }
  ]
};
