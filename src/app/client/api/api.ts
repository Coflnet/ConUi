export * from './auth.service';
import { AuthService } from './auth.service';
export * from './person.service';
import { PersonService } from './person.service';
export * from './search.service';
import { SearchService } from './search.service';
export const APIS = [AuthService, PersonService, SearchService];
