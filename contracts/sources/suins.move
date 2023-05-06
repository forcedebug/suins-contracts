module suins::suins {
    use std::option::{Self, some, none, Option};
    use std::string::String;

    use sui::tx_context::{sender, Self, TxContext};
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::dynamic_field as df;
    use sui::object::{Self, UID};
    use sui::table::{Self, Table};
    use sui::clock::Clock;
    use sui::transfer;
    use sui::sui::SUI;

    use suins::registration_nft::{Self as nft, RegistrationNFT};
    use suins::name_record::{Self, NameRecord};
    use suins::domain::{Self, Domain};

    /// Trying to withdraw from an empty balance.
    const ENoProfits: u64 = 0;
    /// Trying to access a name record that belongs to another account.
    const ENotRecordOwner: u64 = 1;
    /// An application is not authorized to access the feature.
    const EAppNotAuthorized: u64 = 2;
    /// Beep boop.
    const EDefaultDomainNameNotMatch: u64 = 3;
    /// The `RegistrationNFT` has expired.
    const ENftExpired: u64 = 4;
    /// Trying to use a `RegistrationNFT` that expired and was replaced.
    const ENftIdNotMatch: u64 = 5;

    /// An admin capability. The admin has full control over the application.
    /// This object must be issued only once during module initialization.
    struct AdminCap has key, store { id: UID }

    /// The main application object. Stores the state of the application,
    /// used for adding / removing and reading name records.
    struct SuiNS has key {
        id: UID,
        /// The total balance of the SuiNS.
        balance: Balance<SUI>,
        /// Maps domain names to name records (instance of `NameRecord`).
        /// `String => (T = NameRecord { nft_id, target_address })`
        registry: UID,
        /// Map from addresses to a configured default domain.
        reverse_registry: Table<address, String>
    }

    /// The one-time-witness used to claim Publisher object.
    struct SUINS has drop {}

    // === Keys ===

    /// Key under which a configuration is stored. It is type dependent, so
    /// that different configurations can be stored at the same time. Eg
    /// currently we store application `Config` and `Promotion` configuration.
    struct ConfigKey<phantom Config> has copy, store, drop {}

    /// Module initializer:
    /// - create SuiNS object
    /// - create admin capability
    /// - claim Publisher object (for Display and TransferPolicy)
    fun init(otw: SUINS, ctx: &mut TxContext) {
        sui::package::claim_and_keep(otw, ctx);

        // Create the admin capability; only performed once.
        transfer::transfer(AdminCap {
            id: object::new(ctx),
        }, tx_context::sender(ctx));

        let suins = SuiNS {
            id: object::new(ctx),
            balance: balance::zero(),
            registry: object::new(ctx),
            reverse_registry: table::new(ctx),
        };

        transfer::share_object(suins);
    }

    // === Admin actions ===

    /// Withdraw from the SuiNS balance directly and access the Coins within the same
    /// transaction. This is useful for the admin to withdraw funds from the SuiNS
    /// and then send them somewhere specific or keep at the address.
    public fun withdraw(_: &AdminCap, self: &mut SuiNS, ctx: &mut TxContext): Coin<SUI> {
        let amount = balance::value(&self.balance);
        assert!(amount > 0, ENoProfits);
        coin::take(&mut self.balance, amount, ctx)
    }

    // === App Auth ===

    /// An authorization Key kept in the SuiNS - allows applications access
    /// protected features of the SuiNS (such as app_add_balance, app_add_record
    /// etc.)
    /// The `App` type parameter is a witness which should be defined in the
    /// original module (Controller, Registry, Registrar - whatever).
    struct AppKey<phantom App: drop> has copy, store, drop {}

    /// Authorize an application to access protected features of the SuiNS.
    public fun authorize_app<App: drop>(_: &AdminCap, self: &mut SuiNS) {
        df::add(&mut self.id, AppKey<App>{}, true);
    }

    /// Deauthorize an application by removing its authorization key.
    public fun deathorize_app<App: drop>(_: &AdminCap, self: &mut SuiNS): bool {
        df::remove(&mut self.id, AppKey<App>{})
    }

    /// Check if an application is authorized to access protected features of
    /// the SuiNS.
    public fun is_app_authorized<App: drop>(self: &SuiNS): bool {
        df::exists_(&self.id, AppKey<App>{})
    }

    // === Protected features ===

    /// Mutable access to `SuiNS.UID` for authorized applications.
    public fun app_uid_mut<App: drop>(_: App, self: &mut SuiNS): &mut UID {
        assert!(is_app_authorized<App>(self), EAppNotAuthorized);
        &mut self.id
    }

    /// Add a new record to the SuiNS.
    /// The only way to register new records and create `RegistrationNFT`s.
    ///
    /// TODO we need to do better invariant checking here, if a record exists we don't want to override it if it hasn't expired yet
    public fun app_add_record<App: drop>(
        _: App,
        self: &mut SuiNS,
        domain: Domain,
        no_years: u8,
        clock: &Clock,
        ctx: &mut TxContext
    ): RegistrationNFT {
        assert!(is_app_authorized<App>(self), EAppNotAuthorized);

        let nft = nft::new(domain, no_years, clock, ctx);
        let name_record = name_record::new(object::id(&nft), nft::expiration_timestamp_ms(&nft));
        if (has_name_record(self, domain)) {
            let record = df::borrow_mut(&mut self.registry, domain);
            let old_target_address = name_record::target_address(record);
            *record = name_record;

            handle_invalidate_reverse_record(self, domain, old_target_address, none());
        } else {
            df::add(&mut self.registry, domain, name_record)
        };

        nft
    }

    /// Adds balance to the SuiNS.
    public fun app_add_balance<App: drop>(_: App, self: &mut SuiNS, balance: Balance<SUI>) {
        assert!(is_app_authorized<App>(self), EAppNotAuthorized);
        balance::join(&mut self.balance, balance);
    }

    // === Config management ===

    /// Attach dynamic configuration object to the application.
    public fun add_config<Config: store + drop>(_: &AdminCap, self: &mut SuiNS, config: Config) {
        df::add(&mut self.id, ConfigKey<Config> {}, config);
    }

    /// Borrow configuration object. Read-only mode for applications.
    public fun get_config<Config: store + drop>(self: &SuiNS): &Config {
        df::borrow(&self.id, ConfigKey<Config> {})
    }

    /// Get the configuration object for editing. The admin should put it back
    /// after editing (no extra check performed). Can be used to swap
    /// configuration since the `T` has `drop`. Eg nothing is stopping the admin
    /// from removing the configuration object and adding a new one.
    ///
    /// Fully taking the config also allows for edits within a transaction.
    public fun remove_config<Config: store + drop>(_: &AdminCap, self: &mut SuiNS): Config {
        df::remove(&mut self.id, ConfigKey<Config> {})
    }

    // === Ex Registry Code ===

    public fun set_target_address(
        self: &mut SuiNS, token: &RegistrationNFT, clock: &Clock, new_target: address
    ) {
        assert!(!nft::has_expired_with_grace(token, clock), ENftExpired);

        let domain = nft::domain(token);
        let record: &mut NameRecord = df::borrow_mut(&mut self.registry, domain);
        let old_target = name_record::target_address(record);

        name_record::set_target_address(record, some(new_target));
        handle_invalidate_reverse_record(self, domain, old_target, some(new_target));
    }

    public fun unset_target_address(self: &mut SuiNS, token: &RegistrationNFT, clock: &Clock) {
        assert!(!nft::has_expired_with_grace(token, clock), ENftExpired);

        let domain = nft::domain(token);
        let record: &mut NameRecord = df::borrow_mut(&mut self.registry, domain);
        let old_target = name_record::target_address(record);

        name_record::set_target_address(record, none());
        handle_invalidate_reverse_record(self, domain, old_target, none());
    }

    // default domain name setting (address => domain lookup)
    // what do we expect form this feature?

    public fun default_domain(self: &SuiNS, for: address): String {
        *table::borrow(&self.reverse_registry, for)
    }

    public fun target_address(self: &SuiNS, domain: String): Option<address> {
        name_record::target_address(df::borrow(&self.registry, domain))
    }

    // linking address and RegistrationNFT

    public fun set_default_domain(self: &mut SuiNS, token: &RegistrationNFT, clock: &Clock, ctx: &mut TxContext) {
        assert!(!nft::has_expired_with_grace(token, clock), ENftExpired);

        let sender = sender(ctx);
        let domain = nft::domain(token);
        let record = df::borrow(&self.registry, domain);

        assert!(some(sender) == name_record::target_address(record), EDefaultDomainNameNotMatch);

        if (table::contains(&self.reverse_registry, sender)) {
            *table::borrow_mut(&mut self.reverse_registry, sender) = domain::to_string(&domain);
        } else {
            table::add(&mut self.reverse_registry, sender, domain::to_string(&domain));
        };
    }

    // can be performed at any time, right? like I remove a record at my address?
    public fun unset_default_domain(self: &mut SuiNS, ctx: &mut TxContext) {
        table::remove(&mut self.reverse_registry, sender(ctx));
    }

    // === Name Record ===

    /// Read the `name_record` for the specified `domain`.
    public fun name_record<Record: store + drop>(self: &SuiNS, domain: Domain): &Record {
        df::borrow(&self.registry, domain)
    }

    // /// Mutable access to the name record.
    // public fun name_record_mut<Record: store + drop>(
    //     self: &mut SuiNS, token: &RegistrationNFT, clock: &Clock
    // ): &mut Record {
    //     assert!(!nft::has_expired_with_grace(token, clock), ENftExpired);
    //     df::borrow_mut(&mut self.registry, nft::domain(token))
    // }

    /// Check if the `name_record` exists for the given `Domain`.
    public fun has_name_record(self: &SuiNS, domain: Domain): bool {
        df::exists_(&self.registry, domain)
    }

    // === Friend and Private Functions ===

    fun handle_invalidate_reverse_record(
        self: &mut SuiNS,
        domain: Domain,
        old_target_address: Option<address>,
        new_target_address: Option<address>,
    ) {
        if (old_target_address == new_target_address) {
            return
        };

        if (option::is_none(&old_target_address)) {
            return
        };

        let old_target_address = option::destroy_some(old_target_address);
        let reverse_registry = &mut self.reverse_registry;

        if (table::contains(reverse_registry, old_target_address)) {
            let default_domain = table::borrow(reverse_registry, old_target_address);
            if (*default_domain == domain::to_string(&domain)) {
                table::remove(reverse_registry, old_target_address);
            }
        };
    }

    // === Testing ===

    #[test_only] use suins::config;
    #[test_only] struct Test has drop {}

    #[test_only]
    /// Wrapper of module initializer for testing
    public fun init_for_testing(ctx: &mut TxContext): SuiNS {
        let admin_cap = AdminCap { id: object::new(ctx) };
        let suins = SuiNS {
            id: object::new(ctx),
            balance: balance::zero(),
            registry: object::new(ctx),
            reverse_registry: table::new(ctx),
        };

        authorize_app<Test>(&admin_cap, &mut suins);
        add_config(&admin_cap, &mut suins, config::new(
            vector[],
            1200 * suins::constants::mist_per_sui(),
            200 * suins::constants::mist_per_sui(),
            50 * suins::constants::mist_per_sui(),
        ));
        transfer::transfer(admin_cap, tx_context::sender(ctx));
        suins
    }

    #[test_only]
    public fun share_for_testing(self: SuiNS) {
        transfer::share_object(self)
    }

    #[test_only]
    public fun authorize_app_for_testing<App: drop>(self: &mut SuiNS) {
        df::add(&mut self.id, AppKey<App> {}, true)
    }

    #[test_only]
    /// Add a record for testing purposes.
    public fun add_record_for_testing(
        self: &mut SuiNS, domain_name: String, clock: &Clock, ctx: &mut TxContext
    ): RegistrationNFT {
        app_add_record(Test {}, self, domain::new(domain_name), 1, clock, ctx)
    }
}
