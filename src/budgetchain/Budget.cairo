#[starknet::contract]
pub mod Budget {
    use budgetchain_contracts::base::errors::*;
    use budgetchain_contracts::base::types::{
        ADMIN_ROLE, FundRequest, FundRequestStatus, Milestone, ORGANIZATION_ROLE, Organization,
        Project, TRANSACTION_FUND_RELEASE, TRANSACTION_FUND_RETURN, Transaction,
    };
    use budgetchain_contracts::interfaces::IBudget::IBudget;
    use core::array::{Array, ArrayTrait};
    use core::option::Option;
    use core::result::Result;
    use openzeppelin::access::accesscontrol::{AccessControlComponent, DEFAULT_ADMIN_ROLE};
    use openzeppelin::introspection::src5::SRC5Component;
    use starknet::storage::{
        Map, MutableVecTrait, StorageMapReadAccess, StorageMapWriteAccess, StoragePathEntry,
        StoragePointerReadAccess, StoragePointerWriteAccess, Vec, VecTrait,
    };
    use starknet::{
        ContractAddress, contract_address_const, get_block_timestamp, get_caller_address,
    };

    component!(path: AccessControlComponent, storage: accesscontrol, event: AccessControlEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    // AccessControl Mixin
    #[abi(embed_v0)]
    impl AccessControlImpl =
        AccessControlComponent::AccessControlImpl<ContractState>;
    impl AccessControlInternalImpl = AccessControlComponent::InternalImpl<ContractState>;

    // SRC5 Mixin
    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;

    #[storage]
    struct Storage {
        admin: ContractAddress,
        // Transaction storage
        transaction_count: u64,
        transactions: Map<u64, Transaction>,
        project_count: u64,
        projects: Map<u64, Project>,
        all_transaction_ids: Map<u64, u64>, // index -> transaction_id
        fund_requests: Map<(u64, u64), FundRequest>, // Key: (project_id, request_id)
        fund_requests_count: Map<u64, u64>, // Key: project_id, Value: count of requests
        project_budgets: Map<u64, u128>, // Key: project_id, Value: remaining budget
        org_count: u256,
        organizations: Map<u256, Organization>,
        org_addresses: Map<ContractAddress, bool>,
        org_list: Array<Organization>,
        milestones: Map<(u64, u64), Milestone>, // (project, milestone id) -> Milestone
        org_milestones: Map<ContractAddress, u64>, // org to number of milestones they have
        all_transactions: Vec<Transaction>,
        project_transaction_ids: Map<u64, Vec<u64>>,
        #[substorage(v0)]
        accesscontrol: AccessControlComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        FundsReleased: FundsReleased,
        TransactionCreated: TransactionCreated,
        ProjectAllocated: ProjectAllocated,
        OrganizationAdded: OrganizationAdded,
        AdminAdded: AdminAdded,
        MilestoneCreated: MilestoneCreated,
        MilestoneCompleted: MilestoneCompleted,
        FundsReturned: FundsReturned,
        #[flat]
        AccessControlEvent: AccessControlComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct FundsReleased {
        pub project_id: u64,
        pub request_id: u64,
        pub milestone_id: u64,
        pub amount: u128,
    }

    #[derive(Drop, starknet::Event)]
    struct TransactionCreated {
        id: u256,
        sender: ContractAddress,
        recipient: ContractAddress,
        amount: u128,
        timestamp: u64,
        category: felt252,
        description: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ProjectAllocated {
        pub project_id: u64,
        pub org: ContractAddress,
        pub project_owner: ContractAddress,
        pub total_budget: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct OrganizationAdded {
        pub id: u256,
        pub address: ContractAddress,
        pub name: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct MilestoneCreated {
        pub organization: u256,
        pub project_id: u64,
        pub milestone_description: felt252,
        pub milestone_amount: u256,
        pub created_at: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct AdminAdded {
        pub new_admin: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct MilestoneCompleted {
        pub project_id: u64,
        pub milestone_id: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct FundsReturned {
        pub project_id: u64,
        pub amount: u256,
        pub project_owner: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState, default_admin: ContractAddress) {
        assert(default_admin != contract_address_const::<0>(), ERROR_ZERO_ADDRESS);

        // Initialize access control
        self.accesscontrol.initializer();
        self.accesscontrol._grant_role(DEFAULT_ADMIN_ROLE, default_admin);
        self.accesscontrol._grant_role(ADMIN_ROLE, default_admin);

        // Initialize contract storage
        self.admin.write(default_admin);
        self.transaction_count.write(0);
        self.fund_requests_count.write(0, 0);
        self.project_budgets.write(0, 0);
    }

    #[abi(embed_v0)]
    impl BudgetImpl of IBudget<ContractState> {
        fn create_transaction(
            ref self: ContractState,
            project_id: u64,
            recipient: ContractAddress,
            amount: u128,
            category: felt252,
            description: felt252,
        ) -> Result<u64, felt252> {
            // Validate inputs
            assert(recipient != contract_address_const::<0>(), ERROR_ZERO_ADDRESS);
            assert(amount > 0, ERROR_ZERO_AMOUNT);

            // Get caller address
            let sender = get_caller_address();

            // Get current timestamp
            let timestamp = get_block_timestamp();

            // Get next transaction ID
            let transaction_id = self.transaction_count.read() + 1;

            // Create the transaction
            let transaction = Transaction {
                id: transaction_id,
                project_id,
                sender,
                recipient,
                amount,
                timestamp,
                category,
                description,
            };

            // Store transaction in contract storage
            self.transactions.write(transaction_id, transaction);

            // Store transaction ID in the all_transaction_ids mapping
            self.all_transaction_ids.write(transaction_id - 1, transaction_id);

            // Store transaction in the all_transactions Vec
            self.all_transactions.append().write(transaction);

            // Update transaction count
            self.transaction_count.write(transaction_id);

            // Emit the TransactionCreated event
            self
                .emit(
                    TransactionCreated {
                        id: transaction_id.into(),
                        sender: sender,
                        recipient: recipient,
                        amount: amount,
                        timestamp: timestamp,
                        category: category,
                        description: description,
                    },
                );

            Result::Ok(transaction_id)
        }

        fn get_transaction(self: @ContractState, id: u64) -> Result<Transaction, felt252> {
            assert(id > 0 && id <= self.transaction_count.read(), ERROR_INVALID_TRANSACTION_ID);

            // Transaction IDs are 1-based, but array indices are 0-based
            Result::Ok(self.all_transactions.at(id - 1).read())
        }

        fn get_transaction_count(self: @ContractState) -> u64 {
            self.transaction_count.read()
        }

        fn get_transaction_history(
            self: @ContractState, page: u64, page_size: u64,
        ) -> Result<Array<Transaction>, felt252> {
            // Validate page and page_size
            if page == 0 {
                return Result::Err(ERROR_INVALID_PAGE);
            }

            if page_size == 0 || page_size > 100 {
                return Result::Err(ERROR_INVALID_PAGE_SIZE);
            }

            // Create array to hold dummy transaction data
            let mut transactions_array = ArrayTrait::new();

            // For demonstration, we'll create a few dummy transactions
            let mut i: u64 = 0;
            let transaction_count = if page_size < 5 {
                page_size
            } else {
                5
            };

            while i < transaction_count {
                let tx_id = (page - 1) * page_size + i + 1;

                let dummy_tx = Transaction {
                    id: tx_id,
                    project_id: tx_id,
                    sender: get_caller_address(),
                    recipient: get_caller_address(),
                    amount: (tx_id * 100).into(),
                    timestamp: 0,
                    category: 'DUMMY',
                    description: 'Dummy transaction',
                };

                transactions_array.append(dummy_tx);
                i += 1;
            }

            Result::Ok(transactions_array)
        }

        // New function: Get all transactions for a specific project
        fn get_project_transactions(
            self: @ContractState, project_id: u64, page: u64, page_size: u64,
        ) -> Result<(Array<Transaction>, u64), felt252> {
            if page_size == 0 {
                return Result::Err(ERROR_INVALID_PAGE_SIZE);
            }
            if page == 0 {
                return Result::Err(ERROR_INVALID_PAGE);
            }

            let mut transactions_array = ArrayTrait::new();
            let total_tx_count: u64 = self.transaction_count.read();

            let mut i: u64 = 0;
            while i < total_tx_count {
                let transaction_id = self.all_transaction_ids.read(i);
                let transaction = self.transactions.read(transaction_id);

                if transaction.project_id == project_id {
                    transactions_array.append(transaction);
                }
                i += 1;
            }

            if transactions_array.len() == 0 {
                return Result::Err(ERROR_NO_TRANSACTIONS);
            }

            let start_index = (page - 1) * page_size;
            let end_index = start_index + page_size;
            let total_transactions: u64 = transactions_array.len().into();

            if start_index >= total_transactions {
                return Result::Err(ERROR_INVALID_PAGE);
            }

            let mut paginated_transactions = ArrayTrait::<Transaction>::new();
            let mut j: u64 = start_index;

            while j < end_index && j < total_transactions {
                if let Option::Some(boxed_tx) = transactions_array.get(j.try_into().unwrap()) {
                    let transaction: Transaction = *boxed_tx.unbox();
                    paginated_transactions.append(transaction);
                }
                j += 1;
            }

            Result::Ok((paginated_transactions, total_transactions.into()))
        }

        // Retrieves all fund requests for a given project ID.
        fn get_fund_requests(self: @ContractState, project_id: u64) -> Array<FundRequest> {
            let mut fund_requests_to_return = ArrayTrait::new();

            // Get the total count of fund requests for this project
            let count = self.fund_requests_count.read(project_id);
            assert!(count > 0, "No fund requests found for this project ID");

            // Loop through all fund requests for the project
            let mut current_index = 0;

            while current_index < count {
                let fund_request = self.fund_requests.read((project_id, current_index));
                fund_requests_to_return.append(fund_request);
                current_index += 1;
            }

            fund_requests_to_return
        }

        fn get_admin(self: @ContractState) -> ContractAddress {
            self.admin.read()
        }

        fn set_fund_requests(ref self: ContractState, fund_request: FundRequest, budget_id: u64) {
            self.fund_requests.write((fund_request.project_id, budget_id), fund_request);

            // Update the count for this project
            let current_max_id = self.fund_requests_count.read(fund_request.project_id);
            if budget_id >= current_max_id {
                self.fund_requests_count.write(fund_request.project_id, budget_id + 1_u64);
            }
        }

        fn get_fund_requests_counts(self: @ContractState, project_id: u64) -> u64 {
            self.fund_requests_count.read(project_id)
        }

        fn set_fund_requests_counts(ref self: ContractState, project_id: u64, count: u64) {
            self.fund_requests_count.write(project_id, count);
        }

        fn allocate_project_budget(
            ref self: ContractState,
            org: ContractAddress,
            project_owner: ContractAddress,
            total_budget: u256,
            milestone_descriptions: Array<felt252>,
            milestone_amounts: Array<u256>,
        ) -> u64 {
            let caller = get_caller_address();
            assert(self.org_addresses.entry(org).read(), ERROR_UNAUTHORIZED);
            assert(caller == org, ERROR_CALLER_NOT_ORG);

            // Validation - arrays have the same length
            let milestone_count = milestone_descriptions.len();
            assert(milestone_count == milestone_amounts.len(), ERROR_ARRAY_LENGTH_MISMATCH);

            let mut sum: u256 = 0;
            let mut i: u32 = 0;
            while i < milestone_count {
                sum += *milestone_amounts.at(i.into());
                i += 1;
            }
            assert(sum == total_budget, ERROR_BUDGET_MISMATCH);

            let project_id = self.project_count.read();

            let new_project = Project {
                id: project_id, org: org, owner: project_owner, total_budget: total_budget,
            };
            self.projects.write(project_id, new_project);

            // Create milestone records
            let mut j: u32 = 0;
            while j < milestone_count {
                self
                    .milestones
                    .write(
                        (project_id, j.into() + 1),
                        Milestone {
                            organization: org,
                            project_id: project_id,
                            milestone_description: *milestone_descriptions.at(j),
                            milestone_amount: *milestone_amounts.at(j),
                            created_at: get_block_timestamp(),
                            completed: false,
                            released: false,
                        },
                    );
                j += 1;
            }

            self.project_count.write(project_id + 1);
            self.org_milestones.write(org, milestone_count.try_into().unwrap());

            // Emit event
            self.emit(ProjectAllocated { project_id, org, project_owner, total_budget });

            project_id
        }

        fn create_organization(
            ref self: ContractState, name: felt252, org_address: ContractAddress, mission: felt252,
        ) -> u256 {
            // Ensure only the admin can add an organization
            let admin = self.admin.read();
            assert(admin == get_caller_address(), ERROR_ONLY_ADMIN);

            let created_at = get_block_timestamp();
            // // Generate a unique organization ID
            let org_id: u256 = self.org_count.read();

            // Create and store the organization
            let organization = Organization {
                id: org_id,
                address: org_address,
                name,
                is_active: true,
                mission,
                created_at: created_at,
            };

            self.org_count.write(org_id + 1);
            self.organizations.write(org_id, organization);
            self.org_addresses.write(org_address, true);

            // Grant organization role
            self.accesscontrol._grant_role(ORGANIZATION_ROLE, organization.address);

            // Emit an event
            self.emit(OrganizationAdded { id: org_id, address: org_address, name: name });

            org_id
        }

        fn create_milestone(
            ref self: ContractState,
            org: ContractAddress,
            project_id: u64,
            milestone_description: felt252,
            milestone_amount: u256,
        ) -> u64 {
            let admin = self.admin.read();
            assert(admin == get_caller_address(), ERROR_ONLY_ADMIN);

            let created_at = get_block_timestamp();

            let new_milestone: Milestone = Milestone {
                organization: org,
                project_id: project_id,
                milestone_description: milestone_description,
                milestone_amount: milestone_amount,
                created_at: created_at,
                completed: false,
                released: false,
            };
            // // read the number of the current milestones the organization has
            let current_milestone = self.org_milestones.read(org);

            self.milestones.write((project_id, current_milestone + 1), new_milestone);
            self.org_milestones.write(org, current_milestone + 1);

            current_milestone + 1
        }

        fn get_milestone(self: @ContractState, project_id: u64, milestone_id: u64) -> Milestone {
            self.milestones.read((project_id, milestone_id))
        }

        fn get_organization(self: @ContractState, org_id: u256) -> Organization {
            let organization = self.organizations.read(org_id);
            organization
        }

        fn get_project_remaining_budget(self: @ContractState, project_id: u64) -> u256 {
            let project = self.projects.read(project_id);
            project.total_budget
        }

        fn get_project(self: @ContractState, project_id: u64) -> Project {
            self.projects.read(project_id)
        }

        fn get_fund_request(self: @ContractState, project_id: u64, request_id: u64) -> FundRequest {
            self.fund_requests.read((project_id, request_id))
        }

        fn create_fund_request(ref self: ContractState, project_id: u64, milestone_id: u64) -> u64 {
            // Verify project exists
            let project = self.projects.read(project_id);
            assert(project.org != contract_address_const::<0>(), ERROR_INVALID_PROJECT_ID);

            // Confirm project owner
            let caller = get_caller_address();
            assert(caller == project.owner, ERROR_UNAUTHORIZED);

            // Verify milestone exists
            let milestone = self.milestones.read((project_id, milestone_id));
            assert(milestone.project_id == project_id, ERROR_INVALID_MILESTONE);

            // Validate milestone status
            assert(milestone.completed == true, ERROR_INCOMPLETE_MILESTONE);

            // Create fund request
            let fund_request = FundRequest {
                project_id,
                milestone_id,
                amount: milestone.milestone_amount.try_into().unwrap(),
                requester: caller,
                status: FundRequestStatus::Pending,
            };

            // Store the fund request and increase the count
            let request_id = self.fund_requests_count.read(project_id) + 1;
            self.fund_requests.write((project_id, request_id), fund_request);
            self.fund_requests_count.write(project_id, request_id);

            request_id
        }

        fn set_milestone_complete(ref self: ContractState, project_id: u64, milestone_id: u64) {
            // Get the milestone
            let mut milestone = self.milestones.read((project_id, milestone_id));

            // Verify caller's authorization
            let caller = get_caller_address();
            let admin = self.admin.read();
            let project = self.projects.read(project_id);

            // Caller must be either project owner or admin
            assert(caller == project.owner || caller == admin, ERROR_UNAUTHORIZED);

            // Verify the milestone exists for this project
            assert(milestone.project_id == project_id, ERROR_INVALID_MILESTONE);

            // Validate milestone status
            assert(milestone.completed != true, ERROR_MILESTONE_ALREADY_COMPLETED);

            // Update the completed status
            milestone.completed = true;

            // Write back to storage
            self.milestones.write((project_id, milestone_id), milestone);

            // Emit the MilestoneCompleted event
            self.emit(Event::MilestoneCompleted(MilestoneCompleted { project_id, milestone_id }));
        }

        /// Allows authorized organizations to release funds for approved requests
        fn release_funds(
            ref self: ContractState, org: ContractAddress, project_id: u64, request_id: u64,
        ) {
            // Verify caller is an authorized organization
            self.accesscontrol.assert_only_role(ORGANIZATION_ROLE);

            // Ensure caller is the organization associated with the project
            let caller = get_caller_address();
            assert(org == caller, ERROR_ONLY_ORGANIZATION);
            let mut project = self.projects.read(project_id);
            assert(org == project.org, ERROR_ONLY_ORGANIZATION);

            // Validate fund request
            let mut request = self.fund_requests.read((project_id, request_id));
            assert(request.project_id == project_id, ERROR_INVALID_PROJECT_ID);
            assert(request.status == FundRequestStatus::Pending, ERROR_REQUEST_NOT_PENDING);

            // Verify milestone status
            let mut milestone = self.milestones.read((project_id, request.milestone_id));
            assert(milestone.project_id == project_id, ERROR_INVALID_MILESTONE);
            assert(milestone.completed == true, ERROR_INCOMPLETE_MILESTONE);
            assert(milestone.released != true, ERROR_REWARDED_MILESTONE);

            // Confirm project budget has sufficient allocation
            assert(project.total_budget >= request.amount.into(), ERROR_INSUFFICIENT_BUDGET);

            // Update the request status to Approved
            request.status = FundRequestStatus::Approved;
            self.fund_requests.write((project_id, request_id), request);

            // Mark the project milestone as released
            milestone.released = true;
            self.milestones.write((project_id, request.milestone_id), milestone);

            // Update the project's remaining budget
            project.total_budget -= request.amount.into();
            self.projects.write(project_id, project);

            // Create Transaction record and add to tx history
            let transaction_id = self.transaction_count.read() + 1;

            let transaction = Transaction {
                id: transaction_id,
                project_id,
                sender: org,
                recipient: request.requester,
                amount: request.amount,
                timestamp: get_block_timestamp(),
                category: TRANSACTION_FUND_RELEASE,
                description: milestone.milestone_description,
            };

            // Save transaction ID to project transaction IDs
            self.project_transaction_ids.entry(project_id).append().write(transaction_id);

            // Save transaction to all transactions array
            self.all_transactions.append().write(transaction);

            // Update transaction counter
            self.transaction_count.write(transaction_id);

            // Emit the FundsReleased event
            self
                .emit(
                    Event::FundsReleased(
                        FundsReleased {
                            project_id,
                            request_id,
                            milestone_id: request.milestone_id.into(),
                            amount: request.amount,
                        },
                    ),
                );
        }

        /// Allows project owners to return unused funds
        fn return_funds(ref self: ContractState, project_id: u64, amount: u256) {
            // Validate inputs
            assert(amount > 0_u256, ERROR_ZERO_AMOUNT);

            // Get the project details
            let mut project = self.projects.read(project_id);
            assert(project.id == project_id, ERROR_INVALID_PROJECT_ID);

            // Verify caller is the project owner
            let caller = get_caller_address();
            assert(caller == project.owner, ERROR_UNAUTHORIZED);

            // Ensure project has sufficient funds to return
            assert(project.total_budget >= amount, ERROR_INSUFFICIENT_BUDGET);

            // Update the project's remaining budget
            project.total_budget -= amount;
            self.projects.write(project_id, project);

            // Create a transaction record for the returned funds
            let transaction_id = self.transaction_count.read() + 1;

            // Record the transaction (send funds back to the organization)
            let transaction = Transaction {
                id: transaction_id,
                project_id,
                sender: caller,
                recipient: project.org,
                amount: amount.try_into().unwrap(),
                timestamp: get_block_timestamp(),
                category: TRANSACTION_FUND_RETURN,
                description: 'Returned unused funds',
            };

            // Save transaction ID to project transaction IDs
            self.project_transaction_ids.entry(project_id).append().write(transaction_id);

            // Save transaction to all transactions array
            self.all_transactions.append().write(transaction);

            // Update transaction counter
            self.transaction_count.write(transaction_id);

            // Emit the TransactionCreated event
            self
                .emit(
                    TransactionCreated {
                        id: transaction_id.into(),
                        sender: caller,
                        recipient: project.org,
                        amount: amount.try_into().unwrap(),
                        timestamp: get_block_timestamp(),
                        category: TRANSACTION_FUND_RETURN,
                        description: 'Returned unused funds',
                    },
                );

            // Emit the FundsReturned event
            self
                .emit(
                    Event::FundsReturned(
                        FundsReturned { project_id, amount, project_owner: caller },
                    ),
                );
        }
    }
}
