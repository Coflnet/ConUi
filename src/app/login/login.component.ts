import { CommonModule, isPlatformBrowser } from '@angular/common';
import { Component, Inject, PLATFORM_ID } from '@angular/core';
import { HttpClientModule } from '@angular/common/http';

import { SocialAuthService, GoogleSigninButtonModule } from '@abacritt/angularx-social-login';
import { AuthService } from '../AuthService';
import { MatButtonModule } from '@angular/material/button';


@Component({
  selector: 'app-login',
  standalone: true,
  imports: [GoogleSigninButtonModule, CommonModule, HttpClientModule, MatButtonModule],
  templateUrl: './login.component.html',
  styleUrl: './login.component.scss'
})
export class LoginComponent {
  public isBrowser;

  constructor(@Inject(PLATFORM_ID) private platformId: any,
    private authService: SocialAuthService,
    private ownauthService: AuthService) {
    this.isBrowser = isPlatformBrowser(platformId);
    this.authService.authState.subscribe((user) => {
      console.log('authState', user);
      let data = user.authToken;
      ownauthService.googleLogin(user.idToken);
      ownauthService.storeUserData(user);
    });
  }

  signInAnnonymously() {
    this.ownauthService.signInAnnonymously();
  }
}
