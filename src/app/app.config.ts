import { ApplicationConfig, provideZoneChangeDetection } from '@angular/core';
import { provideRouter } from '@angular/router';

import { routes } from './app.routes';
import { provideClientHydration } from '@angular/platform-browser';
import { provideAnimationsAsync } from '@angular/platform-browser/animations/async';

import {
  GoogleLoginProvider,
  SocialAuthServiceConfig,
} from '@abacritt/angularx-social-login';
import { provideHttpClient, withInterceptors } from '@angular/common/http';
import { AuthStorageService, authInterceptor } from './auth.interceptor';
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
    provideHttpClient(withInterceptors([authInterceptor])),
    {
      provide: Configuration,
      useFactory: (authService: AuthStorageService) => new Configuration(
        {
          basePath: environment.basepath
        }
      ),
      deps: [AuthStorageService],
      multi: false
    }
  ]
};
