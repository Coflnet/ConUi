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
  @ViewChild('input', { static: false })
  input: ElementRef<HTMLTextAreaElement> | null = null;
  constructor(private personService: PersonService) { }
  
  ngAfterViewInit() {
    // Focus after the current change detection cycle to avoid
    // ExpressionChangedAfterItHasBeenCheckedError from MatFormField.
    // setTimeout schedules the focus on the next macrotask.
    console.log('field', this.input);
    try {
      if (this.input && this.input.nativeElement) {
        // Focus only when the field is empty (new field) to avoid triggering
        // blur/save cycles on existing fields when multiple are added rapidly.
        const val = (this.input.nativeElement as HTMLTextAreaElement).value;
        if (!val || val.trim().length === 0) {
          setTimeout(() => (this.input as ElementRef<HTMLTextAreaElement>)!.nativeElement.focus());
        }
      }
    } catch (e) {
      // ignore focus errors
    }
  }

  blurred() {
    const val = this.field?.value ?? '';
    if (!val || val.toString().trim().length === 0) {
      // don't save empty values for newly created fields; keep them locally until user enters something
      return;
    }

    // optimistic: mark as saving so the parent / UI can avoid removing it during refresh
    (this.field as any)._saving = true;
    this.personService.addPersonData(this.field).subscribe({
      next: (res) => {
        try {
          // if backend returned a personId or attribute id, attach it to the field
          if (res && res.personId) {
            this.field.personId = res.personId;
          }
        } finally {
          (this.field as any)._saving = false;
          // emit backend response so parent can update person id or refresh view
          this.saved.emit(res);
        }
      },
      error: (err) => {
        console.error('Failed to save field', this.field, err);
        (this.field as any)._saving = false;
        this.saved.emit({ error: err });
      }
    });
  }
}
