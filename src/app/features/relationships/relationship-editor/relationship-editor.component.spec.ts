import { ComponentFixture, TestBed } from '@angular/core/testing';
import { RelationshipEditorComponent } from './relationship-editor.component';
import { provideHttpClient } from '@angular/common/http';
import { provideRouter } from '@angular/router';
import { NoopAnimationsModule } from '@angular/platform-browser/animations';

describe('RelationshipEditorComponent', () => {
  let component: RelationshipEditorComponent;
  let fixture: ComponentFixture<RelationshipEditorComponent>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [RelationshipEditorComponent, NoopAnimationsModule],
      providers: [
        provideHttpClient(),
        provideRouter([])
      ]
    })
    .compileComponents();

    fixture = TestBed.createComponent(RelationshipEditorComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });

  it('should initialize with empty form fields', () => {
    expect(component.fromPersonId).toBeNull();
    expect(component.toPersonId).toBeNull();
    expect(component.relationshipType).toBe('');
    expect(component.certainty).toBe(100);
  });

  it('should have predefined relationship types', () => {
    expect(component.relationshipTypes.length).toBeGreaterThan(0);
    const values = component.relationshipTypes.map(t => t.value);
    expect(values).toContain('Vater');
    expect(values).toContain('Mutter');
    expect(values).toContain('Freund');
  });

  it('should format slider label correctly', () => {
    expect(component.formatLabel(75)).toBe('75%');
    expect(component.formatLabel(100)).toBe('100%');
    expect(component.formatLabel(0)).toBe('0%');
  });
});
