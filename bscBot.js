require("dotenv").config()
const Web3 = require('web3');

const abis = require('./abis');
const addresses = require('./address');


const web3 = new Web3(process.env.INFURA_URL);

const admin = process.env.ADMIN_ADDRESS;


const init = async () => {
    const prediction = new web3.eth.Contract(abis.allora.abi,addresses.allora.address);
        
       //getUserRound(allora);
      // getCurrentEpoch(allora);
       //betBull(allora);
       //getClaimable(allora,14389);
       //claim(allora);
       //checkBet(allora,14452);
       checkExpired(allora,14738);
};

//function to get the ETH balance of the admin
const getEthBalance = async () => {
    const balance = await web3.eth.getBalance(admin);
    console.log(`ETH balance of ADMIN: ${web3.utils.fromWei(balance)}`);
};

//function to get the round
const getUserRound = async (allora) => {
    //get the length first
    const roundLength = await allora.methods.getUserRoundsLength(admin).call();
    const round = await allora.methods.getUserRounds(admin,roundLength-1,roundLength).call();
    //stringify the object to see the values
    console.log(round[0]);
};

//get the latest block number
const getLatestBlock = async () => {
    const block = await web3.eth.getBlock('latest');
    return block.number;
};

//get current epoch
const getCurrentEpoch = async (allora) => {
    // currentEpoch is a public variable in the contract
    const currentEpoch = await allora.methods.currentEpoch().call();
    console.log(`Current epoch: ${currentEpoch}`);
    return currentEpoch;
};

//function to bet bull
const betBull = async (allora) => {
    // get 10% of the admin's balance
    const balance = await web3.eth.getBalance(admin);
    let value = balance * 0.1;
     //convert to ether
     //value = web3.utils.fromWei(value.toString());
    //console.log(`Betting ${value} on BULL`);

    //get the minimum bet amount
    const minBetAmount = await allora.methods.minBetAmount().call();
    //console.log(`Minimum bet amount: ${minBetAmount}`);

    //check if the value is greater than the minimum bet amount
    if(value < minBetAmount){
        console.log(`Value must be greater than ${minBetAmount}`);
        return;
    }else{
        //show the value and minBetAmount in ether
        console.log(`Value: ${web3.utils.fromWei(value.toString())} ETH`);
        console.log(`Minimum bet amount: ${web3.utils.fromWei(minBetAmount)} ETH`);
    }

   

    //get the current epoch
    const currentEpoch = await allora.methods.currentEpoch().call();
    let txx = await allora.methods.betBull(currentEpoch);

    //gas estimation
    const gas = await txx.estimateGas({from: admin, value});
    console.log(`Gas: ${gas}`);
  
    //gas price
    const gasPrice = await web3.eth.getGasPrice();
    //data
    const data = txx.encodeABI();
    //nonce
    const nonce = await web3.eth.getTransactionCount(admin);

    

    const tx = {
        from: admin,
        to: addresses.allora.address,
        data,
        gas,
        gasPrice,
        nonce,
        value
    };

    console.log(tx);

   

    const signedTx =  await web3.eth.accounts.signTransaction (tx, process.env.PRIVATE_KEY );

    const receipt = await web3.eth.sendSignedTransaction(signedTx.rawTransaction);

    console.log(receipt);
    
};

//function to bet bear
const betBear = async (allora) => {
    const amount = web3.utils.toWei('0.1');
    await allora.methods.betBear().send({from: admin, value: amount});
};

//function to withdraw
const withdraw = async () => {
    await allora.methods.withdraw().send({from: admin});
};

//function to claim
const claim = async (allora) => {
    //get the current epoch
    //const currentEpoch = await allora.methods.currentEpoch().call();
    const txx = await allora.methods.claim([14363,14364]);

    //gas estimation
    const gas = await txx.estimateGas({from: admin});
    console.log(`Gas: ${gas}`);

    //gas price
    const gasPrice = await web3.eth.getGasPrice();

    //data
    const data = txx.encodeABI();

    //nonce
    const nonce = await web3.eth.getTransactionCount(admin);

    const tx = {
        from: admin,
        to: addresses.allora.address,
        data,
        gas,
        gasPrice,
        nonce
    };

    console.log(tx);

    const signedTx = await web3.eth.accounts.signTransaction(tx, process.env.PRIVATE_KEY);

    const receipt = await web3.eth.sendSignedTransaction(signedTx.rawTransaction);

    console.log(receipt);
};

//function to get if it is clamable
const getClaimable = async (allora, epoch = null) => {
    //get the current epoch
    epoch = epoch || await allora.methods.currentEpoch().call();
    //const currentEpoch = await allora.methods.currentEpoch().call();
    const claimable = await allora.methods.claimable(epoch,admin).call();
    console.log(claimable);
    return claimable;
};

//function to check if this epoch is already get a bet
const checkBet = async (allora,epoch) => {
    const roundLength = await allora.methods.getUserRoundsLength(admin).call();
    // get the 3 last rounds
    let cursor = roundLength - 4;
    const round = await allora.methods.getUserRounds(admin,cursor,roundLength).call();
    let found = false;
    let epochTab = round[0];
    for(let i = 0; i < epochTab.length; i++) {
        if(epochTab[i] == epoch) {
            found = true;
            break;
        }
    }
    console.log(found);
    return found;
};

//function to check if the epoch is expired
const checkExpired = async (allora,epoch) => {
    // a round is expired if the current epoch is greater than the epoch by 1
    const currentEpoch = await allora.methods.currentEpoch().call();
    const expired = currentEpoch > epoch + 1;
    console.log(expired);
    return expired;
};


//getEthBalance();
init();
//getLatestBlock();
