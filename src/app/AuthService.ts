import { Injectable } from '@angular/core';
import { AuthService as OwnAuth } from './client/api/auth.service';
import { BehaviorSubject } from 'rxjs';
import { SocialUser } from '@abacritt/angularx-social-login';
import { getAuth, onAuthStateChanged, signInAnonymously } from "firebase/auth";
import { initializeApp } from 'firebase/app';
import { AuthStorageService } from './auth.interceptor';
import cryptoRandomString from 'crypto-random-string';
import { environment } from '../environments/environment';
initializeApp(environment.firebaseConfig);

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
    storage.setRequestRefresh(() => {
      this.signInAnnonymously();
    });
    if (isLoggedIn)
      return;
    this.startBackgroundLogin();
  }

  startBackgroundLogin() {
    // firebase anonymous login
    const auth = getAuth();
    onAuthStateChanged(auth, (user) => {
      if (user) {
        const uid = user.uid;
        console.log('user is signed in', uid, user);
        user.getIdToken().then((token) => {
          this.ownAuth.loginFirebase({ authToken: token }).subscribe((tokenContainer) => {
            if (tokenContainer.authToken)
              this.storage.setToken(tokenContainer.authToken);
            this.isLoggedIn.next(true);
          });
        });
      } else {
        // User is signed out
        // ...
      }
    });
    
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
    alert('google signin is currently disabled');
  }

  signInAnnonymously() {
    const auth = getAuth();
    signInAnonymously(auth)
      .then(() => {
        console.log('logged in anonymously');
      })
      .catch((error) => {
        console.error('error logging in anonymously', error);
      });
  }
}
