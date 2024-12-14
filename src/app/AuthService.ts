import { Injectable } from '@angular/core';
import { AuthService as OwnAuth } from './client/api/auth.service';
import { BehaviorSubject } from 'rxjs';
import { SocialUser } from '@abacritt/angularx-social-login';
import { AuthStorageService } from './auth.interceptor';
import cryptoRandomString from 'crypto-random-string';

@Injectable({
  providedIn: 'root',
})
export class AuthService {

  // emtis true if user is logged in
  public isLoggedIn: BehaviorSubject<boolean> = new BehaviorSubject<boolean>(false);
  public isLoggingIn: BehaviorSubject<boolean> = new BehaviorSubject<boolean>(false);

  constructor(
    private storage: AuthStorageService,
    private ownAuth: OwnAuth) {
    const isLoggedIn = this.isAuthenticated();
    this.isLoggedIn.next(isLoggedIn);
    if (isLoggedIn)
      return;

  }

  public isAuthenticated(): boolean {
    let token = this.storage.getToken();
    if (token == null)
      return false;
    let parts = token.split('.');
    if (parts.length != 3)
      return false;
    let payload = JSON.parse(atob(parts[1]));
    let exp = payload.exp;
    if (exp == null)
      return false;
    let now = Math.floor(Date.now() / 1000);
    return now < exp;
  }

  public logout(): void {
    localStorage.removeItem('token');
    // reload page to clear all state
    window.location.reload();
  }

  public getAccessToken(): string | null {
    return this.storage.getToken() ?? null;
  }

  public getUserId(): string | null {
    let token = this.getAccessToken();
    if (!token)
      return null;
    let parts = token.split('.');
    if (parts.length != 3)
      return null;
    let payload = JSON.parse(atob(parts[1]));
    return payload.sub;
  }

  public storeUserData(data: SocialUser): void {
    localStorage.setItem('user', JSON.stringify(data));
  }

  public getUserData(): SocialUser | null {
    let data = localStorage.getItem('user');
    if (data == null) {
      let idtoken = localStorage.getItem('idtoken');
      if (idtoken == null)
        return null;
      let decoded = JSON.parse(atob(idtoken.split('.')[1]));
      return { name: decoded.name, email: decoded.email, photoUrl: decoded.picture } as SocialUser;
    }
    return JSON.parse(data);
  }

  public googleLogin(token: string | null = null): void {
    if (token == null) {
      console.log("no token");
      return;
    }
    if (token == "test") {

      this.storage.setToken(token);
      this.isLoggedIn.next(true);
      return;
    }
    let currentStoed = localStorage.getItem('idtoken');
    if (currentStoed == token)
      return;
    console.log("exchange token", token);
    this.ownAuth.authWithGoogle({ token: token }).subscribe((data) => {
      if (data.token)
        this.storage.setToken(data.token);
      localStorage.setItem('idtoken', token);
      console.log("received exchanged token", data);
      this.isLoggedIn.next(true);
    });
  }
  signInAnnonymously() {
    // get secret from secure storage 
    let secret = localStorage.getItem('secret');
    if (secret == null) {
      // generate cryptographic random secret
      secret = cryptoRandomString({ length: 32 });
      localStorage.setItem('secret', secret);
    }
    var locale = navigator.language;
    this.ownAuth.login({ secret: secret, locale : locale }).subscribe((data) => {
      if (data.token)
        this.storage.setToken(data.token);
      console.log("received exchanged token", data);
      this.isLoggedIn.next(true);
    });
  }
}
