import { Component, ElementRef, EventEmitter, Input, Output, ViewChild } from '@angular/core';
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
  @Output()
  saved = new EventEmitter<any>();
  @ViewChild('input', { static: true })
  input: ElementRef<HTMLTextAreaElement> = null!;
  constructor(private personService: PersonService) { }
  
  ngAfterViewInit() {
    // Focus after the current change detection cycle to avoid
    // ExpressionChangedAfterItHasBeenCheckedError from MatFormField.
    // setTimeout schedules the focus on the next macrotask.
    console.log('field', this.input);
    if (this.input && this.input.nativeElement) {
      setTimeout(() => this.input.nativeElement.focus());
    }
  }

  blurred() {
    this.personService.addPersonData(this.field).subscribe({
      next: (res) => {
        // emit backend response so parent can update person id or refresh view
        this.saved.emit(res);
      },
      error: (err) => {
        console.error('Failed to save field', this.field, err);
        this.saved.emit({ error: err });
      }
    });
  }
}
