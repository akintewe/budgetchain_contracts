use starknet::ContractAddress;

#[derive(Drop, Copy, Serde, PartialEq, starknet::Store)]
pub struct FundRequest {
    pub project_id: u64,
    pub milestone_id: u64,
    pub amount: u128,
    pub requester: ContractAddress,
    pub status: FundRequestStatus,
}

#[derive(Drop, Copy, Serde, PartialEq, starknet::Store)]
#[allow(starknet::store_no_default_variant)]
pub enum FundRequestStatus {
    Pending,
    Approved,
    Rejected,
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct Transaction {
    pub id: u64,
    pub project_id: u64,
    pub sender: ContractAddress,
    pub recipient: ContractAddress,
    pub amount: u128,
    pub timestamp: u64,
    pub category: felt252,
    pub description: felt252,
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct Project {
    pub id: u64,
    pub org: ContractAddress,
    pub owner: ContractAddress,
    pub total_budget: u256,
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct Organization {
    pub id: u256,
    pub address: ContractAddress,
    pub name: felt252,
    pub is_active: bool,
    pub mission: felt252,
    pub created_at: u64,
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct Milestone {
    pub organization: ContractAddress,
    pub project_id: u64,
    pub milestone_description: felt252,
    pub milestone_amount: u256,
    pub created_at: u64,
    pub completed: bool,
    pub released: bool,
}

// ROLE CONSTANTS
pub const ADMIN_ROLE: felt252 = selector!("ADMIN_ROLE");
pub const ORGANIZATION_ROLE: felt252 = selector!("ORGANIZATION_ROLE");

// TRANSACTION CATEGORY CONSTANTS
pub const TRANSACTION_FUND_RELEASE: felt252 = selector!("FUND_RELEASE");
pub const TRANSACTION_FUND_RETURN: felt252 = selector!("FUND_RETURN");
