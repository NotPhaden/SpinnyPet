# SpinnyPet staff setup

Run `supabase/schema.sql` once in Supabase SQL Editor. The file already contains the final fix pack.

If your database already has the old schema, run `supabase/FINAL_FIX.sql` after the old schema.

## Give someone a role

### From SpinnyPet
1. Sign in with an Owner / Co Owner / Manager / Admin account.
2. Open **Admin Panel**.
3. Select the player in the roster (or type their username).
4. Pick the role in the role dropdown.
5. Press **Set Role**.

### Direct SQL
Replace `YOUR_USERNAME`:

```sql
update public.beta_accounts
set role = 'owner', updated_at = now()
where lower(username) = lower('YOUR_USERNAME');
```

Valid roles:

- `owner`
- `co_owner`
- `manager`
- `admin`
- `moderator`
- `helper`
- `user`

For example:

```sql
update public.beta_accounts set role='owner' where username='YourName';
update public.beta_accounts set role='manager' where username='ManagerName';
update public.beta_accounts set role='admin' where username='AdminName';
update public.beta_accounts set role='helper' where username='HelperName';
update public.beta_accounts set role='moderator' where username='ModName';
```

The database function enforces the hierarchy: Owner can grant every role; Co Owner cannot grant Owner; Manager cannot grant Owner/Co Owner; Admin cannot grant Manager/Co Owner/Owner. Helper and Moderator cannot change roles.

## Red vs Blue event

Only Owner, Co Owner, Manager and Admin can enable/disable the event from Admin Panel. Helper and Moderator cannot toggle it.

When enabled, the event page and event sidebar button become visible to everyone. When disabled, they disappear.

## Roblox avatar

The profile box accepts:
- exact Roblox username
- numeric Roblox User ID
- `roblox.com/users/123456/profile`

Display names are not guaranteed to resolve because Roblox's username lookup expects the actual username.
