const fetch = require('node-fetch');
const mysql = require('mysql2');
const util = require('util');
const url = 'https://api.coingecko.com/api/v3/coins/list';
const options = {
  method: 'GET',
  headers: {accept: 'application/json', 'x-cg-api-key': 'CG-69KHCtEFw3Eduz5nrATXWRZs'}
};

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


fetch(url, options)
  .then(res => res.json())
  .then(
    async (json) => {
      console.log(json);
      for (let i = 0; i < json.length; i++) {
        const coin = json[i];
        await query('INSERT INTO coins (id, name, symbol) VALUES (?, ?, ?)', [coin.id, coin.name, coin.symbol]);
      }
      console.log('Coins inserted');
    }
  )
  .catch(err => console.error('error:' + err));