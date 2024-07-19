import { isPlatformBrowser } from '@angular/common';
import { HttpEvent, HttpHandler, HttpHandlerFn, HttpInterceptor, HttpInterceptorFn, HttpRequest } from '@angular/common/http';
import { Inject, Injectable, PLATFORM_ID, inject } from '@angular/core';
import { Observable } from 'rxjs';

export const authInterceptor: HttpInterceptorFn = (
  req: HttpRequest<any>,
  next: HttpHandlerFn
): Observable<HttpEvent<any>> => {
  const cookieService = inject(AuthStorageService);
  const token = cookieService.getToken();
  if (token) {
    const cloned = req.clone({
      setHeaders: {
        authorization: "Bearer " + token,
      },
    });
    console.log('intercepted HTTP call', cloned);
    return next(cloned);
  } else {
    return next(req);
  }
};

@Injectable({
  providedIn: 'root',
})
export class AuthStorageService {
  isBrowser: boolean;
  constructor(@Inject(PLATFORM_ID) private platformId: any) { 
    this.isBrowser = isPlatformBrowser(platformId);
  }
  public getToken(): string | null {
    if (!this.isBrowser)
      return null;
    var token = localStorage.getItem('token');
    return token;
  }

  public setToken(token: string): void {
    localStorage.setItem('token', token);
  }
}

