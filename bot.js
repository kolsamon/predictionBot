require("dotenv").config()
const Web3 = require('web3');
const mysql = require('mysql2');
const util = require('util');
const abis = require('./abis');
const addresses = require('./address');

const web3 = new Web3(process.env.INFURA_URL);

const admin = process.env.ADMIN_ADDRESS;

// Configuration de la connexion MySQL
const db = mysql.createConnection({
    host: 'localhost',
    user: 'root', // Remplace par ton nom d'utilisateur MySQL
    password: '', // Remplace par ton mot de passe MySQL
    database: 'prediction_bot' // Remplace par le nom de ta base de données
});

// Promisify la méthode de requête pour un usage plus simple avec async/await
const query = util.promisify(db.query).bind(db);

// Connexion à la base de données
db.connect((err) => {
    if (err) {
        console.error('Erreur de connexion à la base de données:', err);
        return;
    }
    console.log('Connecté à la base de données MySQL');
});

// charger les informations de base 

const tradeInterval = 5 * 60 * 1000;


const allora = new web3.eth.Contract(abis.allora.abi,addresses.allora.address);


async function execution(allora) {

    try{

        //console.log('New execution at dd/mm/yyyy hh:mm:ss');
        console.log('New execution at ' + new Date().toLocaleString());

    let currentEpoch = await allora.methods.currentEpoch().call();
    let isCurrentEpochBet = await checkBet(allora,currentEpoch);
    
    if(!isCurrentEpochBet) {
        console.log('This epoch is not betted, we will bet it');
        let bet = await betBull(allora);
       // if bet success is true
         if(bet.success) {
              //insert the trade into the database
              console.log(bet.balance);
              await query('INSERT INTO trades (bet_hash,prebalance, bet_amount, bet_fee, epoch, timestamp) VALUES (?, ?, ?, ?, ?, ?)', [bet.hash,bet.balance, bet.betAmount, bet.betFee, bet.epoch, bet.timestamp]);
              console.log('Trade inserted');
            }else{
                console.log('Bet failed');
            }
    }else{
        console.log('This epoch is already betted');
        //check if the last trade is expired
        let isExpired = await checkExpired(allora,(currentEpoch - 1));
        if(isExpired) {
            console.log('This epoch is expired');
           //check if the last trade is claimable
           let  claimable = await allora.methods.claimable((currentEpoch - 1),admin).call();
           if(!claimable) {
                 console.log('This epoch is not claimable');
                //update the trade
                let postBalance = await web3.eth.getBalance(admin);
                postBalance = web3.utils.fromWei(postBalance);
                await query('UPDATE trades SET isclaimed = 1, isclaimable = 0, postbalance = ? WHERE epoch = ?', [postBalance, (currentEpoch - 1)]);
                console.log('Trade updated');
           }else{
                console.log('This epoch is claimable');
                let epochTab = [(currentEpoch - 1)];
                //claim the trade
                let claimResult = await claim(allora, epochTab);
                if(claimResult.success) {
                    //update the trade
                    let postBalance = await web3.eth.getBalance(admin);
                    postBalance = web3.utils.fromWei(postBalance);
                    console.log(postBalance);
                    await query('UPDATE trades SET isclaimed = 1, isclaimable = 1, claimed_fee = ?, postbalance = ? WHERE epoch = ?', [claimResult.fee, postBalance, (currentEpoch - 1)]);
                    console.log('Trade claimed');
                }else{
                    console.log('Claim failed');
                }
           }
        }else{
            console.log('The last epoch is not expired');
        }
    }

    console.log('End execution');

    }catch(e){
        console.log(e);
    }
   
    
}

//function to bet bull
const betBull = async (allora) => {

    // retun object
    let result = {
        success: false,
        hash: null,
        balance: 0,
        betAmount: 0,
        betFee: 0,
        epoch: 0,
        timestamp: 0
    };
    
    try{
            // get 10% of the admin's balance
            const balance = await web3.eth.getBalance(admin);
            let value = balance * 0.1;
            // remove the decimals 
            value = Math.floor(value);
            const minBetAmount = await allora.methods.minBetAmount().call();

            if(value < minBetAmount){
                result.success = false;
                return result;
            }
            //get the current epoch
            const currentEpoch = await allora.methods.currentEpoch().call();
            let txx = await allora.methods.betBull(currentEpoch);

            //gas estimation
            const gas = await txx.estimateGas({from: admin, value});
        
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


            const signedTx =  await web3.eth.accounts.signTransaction (tx, process.env.PRIVATE_KEY );

            const receipt = await web3.eth.sendSignedTransaction(signedTx.rawTransaction);

            result.success = true;
            result.hash = receipt.transactionHash;
            result.balance = web3.utils.fromWei(balance.toString());
            result.betAmount = web3.utils.fromWei(value.toString());
            result.betFee = web3.utils.fromWei((gasPrice * gas).toString());
            result.epoch = currentEpoch;
            result.timestamp = Date.now();
            return result;

    }

catch(e){
    console.log(e);
    result.success = false;
    return result;
}
    
};


//function to claim
const claim = async (allora, epochTab) => {
    
    let result = {
        success: false,
        hash: null,
        fee: 0
    };

    try{

        const txx = await allora.methods.claim(epochTab);

        //gas estimation
        const gas = await txx.estimateGas({from: admin});
    

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


        const signedTx = await web3.eth.accounts.signTransaction(tx, process.env.PRIVATE_KEY);

        const receipt = await web3.eth.sendSignedTransaction(signedTx.rawTransaction);

        result.success = true;
        result.hash = receipt.transactionHash;
        result.fee = web3.utils.fromWei((gasPrice * gas).toString());
        return result;
    }
    catch(e){
        console.log(e);
        result.success = false;
        return result;
    }

    
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
    return found;
};

//function to check if the epoch is expired
const checkExpired = async (allora,epoch) => {
    // a round is expired if the current epoch is greater than the epoch by 1
    const currentEpoch = await allora.methods.currentEpoch().call();
    const expired = currentEpoch > epoch + 1;
    return expired;
};


//send report
const report = async () => {
    // send today trades report
    let todayTrades = await query('SELECT * FROM trades WHERE  DATE(timestamp) = CURDATE()');
    // return total trades, total wins, total losses, net profit, previous balance, current balance, daily profit
    let totalTrades = todayTrades.length;
    let totalWins = 0;
    let totalLosses = 0;
    let netProfit = 0;
    let previousBalance = 0;
    let currentBalance = 0;
    for(let i = 0; i < todayTrades.length; i++) {
        let trade = todayTrades[i];
        if(trade.isclaimed) {
            if(trade.iswin) {
                totalWins++;
                netProfit += trade.postbalance - trade.prebalance;
            }else{
                totalLosses++;
                netProfit -= trade.betAmount;
            }
        }
    }

    let balance = await web3.eth.getBalance(admin);
    previousBalance = todayTrades[0].prebalance;
    currentBalance = web3.utils.fromWei(balance);
    //send the report to the admin
    console.log('Total trades: ' + totalTrades);
    console.log('Total wins: ' + totalWins);
    console.log('Total losses: ' + totalLosses);
    console.log('Net profit: ' + netProfit);
    console.log('Previous balance: ' + previousBalance);
    console.log('Current balance: ' + currentBalance);
    console.log('Daily profit: ' + (currentBalance - previousBalance));
    
};

execution(allora);
const tradeIntervalId = setInterval(() => {
    execution(allora);
}, tradeInterval);