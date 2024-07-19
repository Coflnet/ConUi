import { Component, ElementRef, Input, ViewChild, input } from '@angular/core';
import { PersonData, PersonService } from '../client';
import { FormsModule } from '@angular/forms';
import { MatLabel } from '@angular/material/form-field';
import { MatInput } from '@angular/material/input';
import { MatFormField } from '@angular/material/form-field';
import { NgStyle } from '@angular/common';

@Component({
  selector: 'app-field',
  standalone: true,
  imports: [FormsModule, MatLabel, MatInput, MatFormField, NgStyle],
  templateUrl: './field.component.html',
  styleUrl: './field.component.scss'
})
export class FieldComponent {
  @Input()
  field: PersonData = { name: '', value: '' };
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
