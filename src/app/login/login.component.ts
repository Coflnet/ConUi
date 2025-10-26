import { CommonModule, isPlatformBrowser } from '@angular/common';
import { Component, Inject, PLATFORM_ID } from '@angular/core';
import { ActivatedRoute } from '@angular/router';
import { HttpClientModule } from '@angular/common/http';

import { SocialAuthService, GoogleSigninButtonModule } from '@abacritt/angularx-social-login';
import { AuthService } from '../AuthService';
import { MatButtonModule } from '@angular/material/button';
import { FormsModule } from '@angular/forms';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { Router } from '@angular/router';


@Component({
    selector: 'app-login',
  imports: [GoogleSigninButtonModule, CommonModule, HttpClientModule, MatButtonModule, FormsModule, MatFormFieldModule, MatInputModule],
    templateUrl: './login.component.html',
    styleUrl: './login.component.scss'
})
export class LoginComponent {
  public isBrowser;

  // UI state
  public choosing = true; // true = show choice screen
  public emailMode: 'signIn' | 'create' = 'signIn';
  public email = '';
  public password = '';
  public errorMessage: string | null = null;

  public returnUrl: string | null = null;

  constructor(@Inject(PLATFORM_ID) private platformId: any,
    private authService: SocialAuthService,
    private router: Router,
    private route: ActivatedRoute,
    private ownauthService: AuthService) {
    this.isBrowser = isPlatformBrowser(platformId);

    // Social auth (Google) - keep existing behavior
    this.authService.authState.subscribe((user) => {
      console.log('authState', user);
      if (user) {
        this.ownauthService.googleLogin(user.idToken);
        this.ownauthService.storeUserData(user);
      }
    });

    // capture returnUrl (if any)
    this.returnUrl = this.route.snapshot.queryParams['returnUrl'] ?? null;

    // Navigate when logged in — return to the original URL if present
    ownauthService.isLoggedIn.subscribe((loggedIn) => {
      if (loggedIn) {
        const target = this.returnUrl ?? '/dashboard';
        // use navigateByUrl for arbitrary return URLs
        router.navigateByUrl(target).catch(() => router.navigate(['/dashboard']));
      }
    });
  }

  // Choice actions
  continueAnonymously() {
    // Warn: anonymous users may lose progress and file storage is unavailable
    const ok = confirm('Continue anonymously? You might lose progress if you clear cookies and file storage is not available for anonymous users.');
    if (!ok) return;
    this.ownauthService.signInAnnonymously();
    // The AuthService will emit isLoggedIn on success and the subscription above will navigate back
  }

  chooseEmailSignIn() {
    this.choosing = false;
    this.emailMode = 'signIn';
  }

  chooseEmailCreate() {
    this.choosing = false;
    this.emailMode = 'create';
  }

  backToChoice() {
    this.choosing = true;
    this.errorMessage = null;
  }

  async submitEmailForm() {
    this.errorMessage = null;
    try {
      if (this.emailMode === 'signIn') {
        await this.ownauthService.signInWithEmail(this.email, this.password);
      } else {
        await this.ownauthService.createAccountWithEmail(this.email, this.password);
      }
      // When sign-in/create succeed, AuthService.onAuthStateChanged will exchange tokens and set isLoggedIn,
      // triggering the subscription to navigate back to returnUrl.
    } catch (err: any) {
      console.error('Email auth error', err);
      this.errorMessage = err?.message ?? 'Authentication failed';
    }
  }
}
