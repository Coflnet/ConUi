import { Component, ElementRef, Input, ViewChild } from '@angular/core';
import { PersonAttributeDto, PersonService } from '../client';
import { FormsModule } from '@angular/forms';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { CommonModule, NgStyle } from '@angular/common';

@Component({
    selector: 'app-field',
    standalone: true,
    imports: [CommonModule, FormsModule, MatFormFieldModule, MatInputModule],
    templateUrl: './field.component.html',
    styleUrls: ['./field.component.scss']
})
export class FieldComponent {
  @Input()
  field: PersonAttributeDto = { personId: null, category: null, key: '', value: '' };
  @ViewChild('input', { static: true })
  input: ElementRef<HTMLElement> = null!;
  constructor(private personService: PersonService) { }
  
  ngAfterViewInit() {
    console.log('field', this.input);
    this.input.nativeElement.focus();
  }

  blurred() {
    this.personService.addPersonData(this.field).subscribe();
  }
}
