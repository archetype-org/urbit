import React, { Component } from 'react';
import classnames from 'classnames';


export class LandingScreen extends Component {

  constructor(props) {
    super(props);
  }

  componentDidMount() {
    const { props } = this;
    let station = props.match.params.ship + '/' + props.match.params.station;

    if (station in props.configs) {
      props.history.push(`/~chat/${station}`);
    }
  }

  componentDidUpdate(prevProps, prevState) {
    const { props } = this;
    let station = props.match.params.ship + '/' + props.match.params.station;

    if (station in props.configs) {
      props.history.push(`/~chat/${station}`);
    }
  }

  onClickSubscribe() {
    const { props } = this;
    
    let station = props.match.params.ship + '/' + props.match.params.station;
    let  actions = [
        {
          create: {
            nom: 'hall-internal-' + props.match.params.station,
            des: "chatroom",
            sec: "channel"
          }
        },
        {
          source: {
            nom: "inbox",
            sub: true,
            srs: [station]
          }
        },
        {
          source: {
            nom: "inbox",
            sub: true,
            srs: [`~${window.ship}/hall-internal-${props.match.params.station}`]
          }
        }
    ];

    this.props.api.chat(actions);
    this.props.history.push('/~chat');
  }

  render() {
    const { props } = this;
    let station = props.match.params.ship + '/' + props.match.params.station;

    return (
      <div className="h-100 w-100 pt2 overflow-x-hidden flex flex-column">
        <div className='pl2 pt2 bb'>
          <h2>{station}</h2>
        </div>
        <div className="pa3 pl2">
        <h2 className="body-large">Not Yet Subscribed</h2>
        <p className="body-regular-400">
          You aren't subscribed to this chat yet.
          Subscribe to see its messages and members.
        </p>
        <br />
        <button
          onClick={this.onClickSubscribe.bind(this)}
          className="label-regular fw-bold pointer"
        >Subscribe</button>
        </div>
      </div>
    );
  }
}

