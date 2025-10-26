import { isPlatformBrowser } from '@angular/common';
import { HttpErrorResponse, HttpEvent, HttpHandler, HttpHandlerFn, HttpInterceptor, HttpInterceptorFn, HttpRequest } from '@angular/common/http';
import { Inject, Injectable, PLATFORM_ID, inject } from '@angular/core';
import { Router } from '@angular/router';
import { environment } from '../environments/environment';
import { catchError, Observable, switchMap, throwError } from 'rxjs';

export const authInterceptor: HttpInterceptorFn = (
  req: HttpRequest<any>,
  next: HttpHandlerFn
): Observable<HttpEvent<any>> => {
  const cookieService = inject(AuthStorageService);
  const router = inject(Router);
  const token = cookieService.getToken();
  console.log('authInterceptor: token present?', !!token);
  if (token) {
    const headerValue = `Bearer ${token}`;
    const cloned = req.clone({
      setHeaders: {
        Authorization: headerValue,
      },
    });
    // log minimal info to avoid leaking tokens in logs
    console.log('authInterceptor: attaching Authorization header to', req.url, 'header-present:', !!cloned.headers.get('Authorization'));
    return next(cloned).pipe(
      catchError((error: HttpErrorResponse) => {
        if (error.status === 401) {
          // remove token silently (do not trigger background refresh)
          try { cookieService.removeTokenSilent(); } catch(e) { cookieService.removeToken(); }
          // redirect to login with returnUrl
          try {
            const returnUrl = router.url || req.url || '/dashboard';
            router.navigate(['/login'], { queryParams: { returnUrl } });
          } catch (e) {
            // ignore navigation errors
          }
        }
        console.log('error', error);
        return throwError(()=>error);
      })
    );
  } else {
    console.log('authInterceptor: no token present at intercept time for', req.url, '— waiting briefly for token');
    // Wait up to 1500ms for a token to appear (background login may complete shortly after app start)
    return new Observable<HttpEvent<any>>(observer => {
      let elapsed = 0;
      const interval = 100;
      const handle = setInterval(() => {
        const t = cookieService.getToken();
        if (t) {
          clearInterval(handle);
          const headerValue2 = `Bearer ${t}`;
          const cloned2 = req.clone({ setHeaders: { Authorization: headerValue2 } });
          console.log('authInterceptor: token appeared, retrying request with Authorization for', req.url);
          next(cloned2).subscribe({
            next: (v) => observer.next(v),
            error: (e) => observer.error(e),
            complete: () => observer.complete()
          });
        } else {
          elapsed += interval;
          if (elapsed >= 1500) {
            clearInterval(handle);
            console.log('authInterceptor: token did not appear in time, sending request without Authorization for', req.url);
            next(req).subscribe({
              next: (v) => observer.next(v),
              error: (e) => observer.error(e),
              complete: () => observer.complete()
            });
          }
        }
      }, interval);
      // tear-down
      return () => { clearInterval(handle); };
    });
  }
};

@Injectable({
  providedIn: 'root',
})
export class AuthStorageService {
  isBrowser: boolean;
  requestRefresh =() => {};
  constructor(@Inject(PLATFORM_ID) private platformId: any) { 
    this.isBrowser = isPlatformBrowser(platformId);
    // Dev helper: if running locally and no token is present, seed a short test token
    try {
  if (this.isBrowser && !this.getToken() && (window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1')) {
        // lightweight dummy JWT-like token for local testing only
        const dummy = 'test.' + btoa(JSON.stringify({env:'dev'})) + '.sig';
        localStorage.setItem('token', dummy);
        console.log('AuthStorageService: seeded dev token in localStorage');
      }
    } catch (e) {
      // ignore
    }
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

  public removeToken(): void {
    localStorage.removeItem('token');
    this.requestRefresh();
  }

  /**
   * Remove token silently without invoking the configured requestRefresh action.
   * Use this when the token was rejected by the server and we want to force login.
   */
  public removeTokenSilent(): void {
    try {
      localStorage.removeItem('token');
    } catch (e) {}
  }

  public setRequestRefresh(requestRefresh: ()=>void){
    this.requestRefresh = requestRefresh;
  }
}

