use plainwire_bot::Client;
fn main() -> Result<(),Box<dyn std::error::Error>> {
    let bot=Client::new(&std::env::var("PLAINWIRE_URL")?,&std::env::var("PLAINWIRE_BOT_TOKEN")?)?;
    println!("{}",bot.me()?); Ok(())
}
